<p align="center">
  <img src="./audit-data/act.png" alt="ACT" width="200" />
</p>

<div align="center">

# Thunder Loan

## Smart Contract Security Audit Report

</div>

| | |
| :--- | :--- |
| **Project** | Thunder Loan — flash lending and liquidity-provider vaults |
| **Revision audited** | `8803f851f6b37e99eab2e94b4690c8b70e26b3f6` |
| **Compiler** | Solidity `0.8.20` |
| **Target chain** | Ethereum |
| **Supported assets** | USDC, DAI, LINK, WETH |
| **Report date** | 25 November 2026 |
| **Classification** | Confidential — for the Thunder Loan team only |

---

## Table of Contents

- [1. Executive Summary](#1-executive-summary)
- [2. Scope and Methodology](#2-scope-and-methodology)
- [3. Findings Overview](#3-findings-overview)
- [4. Detailed Findings](#4-detailed-findings)
  - [H-1 — Inflated exchange rate in `deposit()` blocks redemptions and misprices shares](#h-1)
  - [H-2 — Storage layout collision in the planned upgrade freezes the protocol](#h-2)
- [5. Automated Analysis Summary](#5-automated-analysis-summary)
- [6. Disclaimer](#6-disclaimer)

---

## 1. Executive Summary

Thunder Loan is a flash-loan protocol in which liquidity providers deposit ERC-20 assets into `ThunderLoan` and receive `AssetToken` shares. Those shares appreciate as borrowers repay flash loans with a fee. The protocol is upgradeable through a UUPS proxy, and a second implementation, `ThunderLoanUpgraded`, was included in the review.

This assessment combined a manual review of the in-scope contracts with automated static analysis and local proof-of-concept testing. **Two High-severity findings** were identified:

1. **H-1 — Exchange-rate inflation on deposit.** The audited `deposit()` implementation updates the `AssetToken` exchange rate by a hypothetical flash-loan fee that is never collected. The reported asset value therefore exceeds the underlying balance held by the vault. Redemptions can revert, and shares are minted at an incorrect price.
2. **H-2 — Storage collision on upgrade.** `ThunderLoanUpgraded` reorders and removes storage variables relative to the deployed implementation. After the planned upgrade, the fee is read from the wrong slot and the flash-loan guard mapping aliases the old fee slot, which can freeze all deposits, redemptions, and flash loans.

Both issues are actionable before mainnet use. H-1 does not require an attacker — it is triggered by ordinary deposit activity — while H-2 is triggered by the owner-authorised upgrade explicitly contemplated in the project documentation. The team should remediate both findings and re-run the Foundry test suite and storage-layout comparison before deployment.

## 2. Scope and Methodology

### 2.1 Scope

| File | Role |
| :--- | :--- |
| `src/protocol/ThunderLoan.sol` | Core pool, deposit/redeem, flash loans, proxy initialisation |
| `src/protocol/AssetToken.sol` | Share token and exchange-rate accounting |
| `src/protocol/OracleUpgradeable.sol` | Price-oracle plumbing |
| `src/upgradedProtocol/ThunderLoanUpgraded.sol` | Planned UUPS implementation upgrade |
| `src/interfaces/IFlashLoanReceiver.sol` | Borrower callback interface |
| `src/interfaces/IPoolFactory.sol` | External pool factory interface |
| `src/interfaces/ITSwapPool.sol` | External AMM/oracle interface |
| `src/interfaces/IThunderLoan.sol` | Protocol interface |

Aderyn reported 8 Solidity files and 103 nSLOC for the scanned revision.

### 2.2 Roles

- **Owner** — administers allowed tokens, updates the flash-loan fee, and authorises proxy upgrades.
- **Liquidity provider** — deposits supported assets and receives interest-bearing `AssetToken` shares.
- **Borrower (user)** — takes a flash loan and repays the principal plus fee within the same transaction.

### 2.3 Known issues acknowledged by the project

The following were explicitly identified as accepted by the team and are not reported as new findings: zero fees for very small flash loans and associated rounding; the first-depositor advantage in share distribution (to be mitigated by a large initial deposit); and incompatibility with fee-on-transfer, rebasing, and ERC-777 tokens (to be managed by owner vetting of new assets).

### 2.4 Methodology

The review included line-by-line manual inspection of the in-scope contracts, reasoning about exchange-rate and share arithmetic across deposit/redeem/flash-loan state transitions, comparison of proxy storage layouts, and reproduction of the reported issues with Foundry test cases. Automated static analysis was performed with Aderyn; its results are summarised in [Section 5](#5-automated-analysis-summary). Findings are reported against the revision stated above; local working-tree changes made after that revision were not treated as part of the audited code.

## 3. Findings Overview

| ID | Severity | Likelihood | Finding | Affected component |
| :--- | :--- | :--- | :--- | :--- |
| [H-1](#h-1) | **High** | High | Erroneous exchange-rate update in `deposit()` inflates reported fees and blocks redemptions | `ThunderLoan.sol` → `deposit()`, `AssetToken.sol` → `updateExchangeRate()` |
| [H-2](#h-2) | **High** | High | Reordered storage variables in `ThunderLoanUpgraded` cause a storage collision and freeze the protocol | `ThunderLoanUpgraded.sol` → state-variable declarations |

| Severity | Count |
| :--- | ---: |
| Critical | 0 |
| High | 2 |
| Medium | 0 |
| Low | 0 |
| Informational / NC (automated) | 4 |

## 4. Detailed Findings

<a name="h-1"></a>

### H-1 — Inflated exchange rate in `deposit()` blocks redemptions and misprices shares

| | |
| :--- | :--- |
| **Severity** | High |
| **Likelihood** | High — occurs on every deposit in the audited implementation |
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

<a name="h-2"></a>

### H-2 — Storage layout collision in the planned upgrade freezes the protocol

| | |
| :--- | :--- |
| **Severity** | High |
| **Likelihood** | High — triggered by the planned owner-authorised upgrade |
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

## 5. Automated Analysis Summary

The automated scan (Aderyn) reported two Medium and four Informational/NC issues. These are lower-priority than the manual findings above and should be triaged separately; raw tool output remains available in `report.md.backup`.

| ID | Severity | Issue | Reported locations |
| :--- | :--- | :--- | :--- |
| M-1 | Medium | Centralisation risk from trusted owner privileges | `ThunderLoan.sol:239, 265, 292`; `ThunderLoanUpgraded.sol:235, 261, 284` |
| M-2 | Medium | `ERC721::_mint()` can mint to addresses that do not support ERC-721; prefer `_safeMint()` | `AssetToken.sol:69` |
| NC-1 | NC | Missing `address(0)` validation when assigning address state variables | `OracleUpgradeable.sol:16` |
| NC-2 | NC | Functions not used internally could be marked `external` | `ThunderLoan.sol:231, 272, 276, 280`; `ThunderLoanUpgraded.sol:227, 268, 272, 276` |
| NC-3 | NC | Constants should replace literal values | `ThunderLoan.sol:144, 145`; `ThunderLoanUpgraded.sol:144` |
| NC-4 | NC | Events are missing `indexed` fields | `ThunderLoan.sol:105–107, 110`; `AssetToken.sol:31`; `ThunderLoanUpgraded.sol:105–107, 110` |

Aderyn is a static-analysis tool; its output is not a substitute for manual review and is provided here only to assist in identifying potential issues.

## 6. Disclaimer

This report reflects a manual security review of the code at the revision specified in Section 1, together with the supplied finding notes and automated analysis output. It is not a guarantee that the protocol is free of vulnerabilities, nor an endorsement of any deployment. Smart-contract systems carry inherent risk; the team should independently verify all remediations, re-run tests and storage-layout checks, and obtain further review before handling user funds.
