# Thunder Loan — Audit Findings

Complete professional write-ups of the issues identified during the manual review of revision `8803f851f6b37e99eab2e94b4690c8b70e26b3f6`. This file is the source used to assemble `report.md` and its PDF version; no finding detail is abbreviated here.

## Contents

- [H-1 — Inflated exchange rate in `deposit()` blocks redemptions and misprices shares](#h-1)
- [H-2 — Storage layout collision in the planned upgrade freezes the protocol](#h-2)

---

## H-1 — Inflated exchange rate in `deposit()` blocks redemptions and misprices shares

| | |
| :--- | :--- |
| **Severity** | High |
| **Likelihood** | High — occurs on every deposit in the audited implementation |
| **Affected code** | `src/protocol/ThunderLoan.sol` → `deposit()`; `src/protocol/AssetToken.sol` → `updateExchangeRate()` |
| **Impact** | Liquidity-provider funds can become unredeemable; share pricing is incorrect |

**Description**

`AssetToken::s_exchangeRate` converts underlying assets into `AssetToken` shares. It must increase only when additional underlying actually enters the pool — that is, when a flash-loan fee is paid. In the audited implementation, `ThunderLoan::deposit()` computes a hypothetical fee on the deposited amount and passes it to `AssetToken::updateExchangeRate()` *before* transferring any underlying into the vault:

```solidity
function deposit(IERC20 token, uint256 amount)
    external
    revertIfZero(amount)
    revertIfNotAllowedToken(token)
{
    AssetToken assetToken = s_tokenToAssetToken[token];
    uint256 exchangeRate = assetToken.getExchangeRate();
    uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
    emit Deposit(msg.sender, token, amount);
    assetToken.mint(msg.sender, mintAmount);

    // No fee is collected on a deposit, yet the rate is increased as if one were paid.
    uint256 calculatedFee = getCalculatedFee(token, amount);
    assetToken.updateExchangeRate(calculatedFee);

    token.safeTransferFrom(msg.sender, address(assetToken), amount);
}
```

The exchange rate is therefore inflated without a corresponding increase in the vault's underlying balance. The accounting invariant — `exchangeRate × totalSupply` equals the underlying held by the `AssetToken` — no longer holds.

**Impact**

1. `redeem()` values shares using the inflated rate. Once the amount owed exceeds the underlying balance held by `AssetToken`, the final redemptions revert and liquidity providers cannot withdraw their deposits.
2. Shares are minted at a price that does not reflect the assets actually received. Accrued flash-loan fees are misattributed, so providers can receive substantially more or less than they are entitled to.
3. Because the behaviour occurs on every deposit, the distortion compounds with ordinary protocol usage; no malicious actor is required.

**Proof of Concept**

Steps:

1. A liquidity provider deposits supported tokens into the pool.
2. A user takes out a flash loan and repays it with the fee.
3. The liquidity provider attempts to redeem the full share balance (`type(uint256).max`). On the audited revision the redemption fails because the exchange rate claims more underlying than the vault holds.

Place the following test in `test/unit/ThunderLoanTest.t.sol`:

<details>
<summary>Proof of code</summary>

```solidity
function testRedeemAfterLoan() public setAllowedToken hasDeposits {
    uint256 amountToBorrow = AMOUNT * 10;
    uint256 calculatedFee = thunderLoan.getCalculatedFee(tokenA, amountToBorrow);

    vm.startPrank(user);
    tokenA.mint(address(mockFlashLoanReceiver), calculatedFee); // repay the fee
    thunderLoan.flashloan(address(mockFlashLoanReceiver), tokenA, amountToBorrow, "");
    vm.stopPrank();

    uint256 amountToRedeem = type(uint256).max;
    vm.startPrank(liquidityProvider);
    thunderLoan.redeem(tokenA, amountToRedeem); // reverts on the audited revision
    vm.stopPrank();
}
```

</details>

**Recommended Mitigation**

Remove both the fee calculation and the exchange-rate update from `deposit()`. The rate must only be advanced when fees are genuinely credited to the vault:

```diff
     function deposit(IERC20 token, uint256 amount)
         external
         revertIfZero(amount)
         revertIfNotAllowedToken(token)
     {
         AssetToken assetToken = s_tokenToAssetToken[token];
         uint256 exchangeRate = assetToken.getExchangeRate();
         uint256 mintAmount = (amount * assetToken.EXCHANGE_RATE_PRECISION()) / exchangeRate;
         emit Deposit(msg.sender, token, amount);
         assetToken.mint(msg.sender, mintAmount);
-        uint256 calculatedFee = getCalculatedFee(token, amount);
-        assetToken.updateExchangeRate(calculatedFee);
         token.safeTransferFrom(msg.sender, address(assetToken), amount);
     }
```

For additional robustness, accrue the exchange rate in `flashloan()` only after the ending-balance check confirms that `startingBalance + fee` was actually received, so the invariant always reflects realised assets.

---

## H-2 — Storage layout collision in the planned upgrade freezes the protocol

| | |
| :--- | :--- |
| **Severity** | High |
| **Likelihood** | High — triggered by the planned owner-authorised upgrade |
| **Affected code** | `src/upgradedProtocol/ThunderLoanUpgraded.sol` → state-variable declarations |
| **Impact** | Incorrect fee charging, broken reentrancy guard, protocol freeze |

**Description**

`ThunderLoan` is deployed behind a UUPS proxy, so its implementation can be replaced while the proxy's storage persists. An upgrade implementation must therefore preserve the exact storage layout of the original contract. The audited `ThunderLoanUpgraded` does not:

```solidity
// ThunderLoan.sol (deployed implementation)
uint256 private s_feePrecision;   // slot 1
uint256 private s_flashLoanFee;   // slot 2
mapping(IERC20 => bool) private s_currentlyFlashLoaning; // slot 3

// ThunderLoanUpgraded.sol (audited upgrade)
uint256 private s_flashLoanFee;   // slot 1 — collides with s_feePrecision
uint256 public constant FEE_PRECISION = 1e18; // constants do not consume storage
mapping(IERC20 => bool) private s_currentlyFlashLoaning; // slot 2 — collides with s_flashLoanFee
```

Removing `s_feePrecision` shifts every subsequent variable one slot earlier. Solidity `constant` declarations occupy no storage and cannot be used to reserve the vacated slot.

**Impact**

| Slot | Value in proxy before upgrade | Interpretation after upgrade |
| :--- | :--- | :--- |
| 1 | `s_feePrecision = 1e18` | `s_flashLoanFee = 1e18` (a 100% fee) |
| 2 | `s_flashLoanFee = 3e15` (0.3%) | `s_currentlyFlashLoaning` mapping storage |
| 3 | `s_currentlyFlashLoaning` | Orphaned — no longer read by the new implementation |

1. `getFee()` returns `1e18` after the upgrade, so `getCalculatedFee()` would charge a fee equal to the entire borrowed amount. Legitimate flash loans cannot be repaid and revert.
2. Because slot 2 contains the old, non-zero fee value, any token looked up in `s_currentlyFlashLoaning` appears to be in an active flash loan. `revertIfCurrentlyFlashLoaning()` then blocks `deposit()`, `redeem()`, and `flashloan()` — effectively freezing the protocol. Writing the guard flag also overwrites the fee slot, compounding the corruption.
3. Any later upgrade built on this layout inherits the corrupted state.

**Proof of Concept**

The layout drift can be confirmed with:

```shell
forge inspect ThunderLoan storage
forge inspect ThunderLoanUpgraded storage
```

And reproduced with the following test (using the audited upgrade implementation):

```solidity
import {ThunderLoanUpgraded} from "../src/upgradedProtocol/ThunderLoanUpgraded.sol";

function testUpgradeCorruptsFee() public {
    uint256 feeBeforeUpgrade = thunderLoan.getFee(); // 3e15

    vm.prank(thunderLoan.owner());
    ThunderLoanUpgraded upgraded = new ThunderLoanUpgraded();
    thunderLoan.upgradeToAndCall(address(upgraded), "");

    uint256 feeAfterUpgrade = thunderLoan.getFee(); // 1e18 — reads s_feePrecision
    assertEq(feeBeforeUpgrade, 3e15);
    assertEq(feeAfterUpgrade, 1e18);
}
```

**Recommended Mitigation**

Never remove or reorder storage variables in an upgrade implementation. Reserve the vacated slot so that `s_flashLoanFee` and the `s_currentlyFlashLoaning` mapping keep their original positions:

```diff
-    uint256 private s_flashLoanFee; // 0.3% ETH fee
-    uint256 public constant FEE_PRECISION = 1e18;
+    uint256 private s_feePrecisionReserved; // formerly s_feePrecision; retained for layout compatibility
+    uint256 private s_flashLoanFee; // 0.3% ETH fee
+    uint256 public constant FEE_PRECISION = 1e18;
```

The mapping declaration must remain third in order, at slot 3. Do not initialise or overwrite the reserved slot in the upgrade implementation, and avoid re-running `initialize()` against existing proxy state. Add a storage-layout comparison (for example, `forge inspect <contract> storage` diffing or an upgrades-plugin validation step) to CI so any future layout drift is rejected before deployment.
