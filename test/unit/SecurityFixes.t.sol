// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { BaseTest, ThunderLoan } from "./BaseTest.t.sol";
import { AssetToken } from "../../src/protocol/AssetToken.sol";
import { ThunderLoanUpgraded } from "../../src/upgradedProtocol/ThunderLoanUpgraded.sol";
import { MockFlashLoanReceiver } from "../mocks/MockFlashLoanReceiver.sol";
import { ERC20Mock } from "../mocks/ERC20Mock.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract SixDecimalsMock is ERC20 {
    constructor() ERC20("Six", "SIX") { }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract FeeOnTransferMock is ERC20 {
    constructor() ERC20("Fee", "FEE") { }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (from != address(0) && to != address(0)) {
            uint256 fee = value / 100;
            super._update(from, address(0), fee);
            super._update(from, to, value - fee);
        } else {
            super._update(from, to, value);
        }
    }
}

interface IDepositThunderLoan {
    function deposit(IERC20 token, uint256 amount) external;
    function repay(IERC20 token, uint256 amount) external;
}

contract DepositDuringFlashLoanReceiver {
    using SafeERC20 for IERC20;

    function executeOperation(
        address token,
        uint256 amount,
        uint256 fee,
        address,
        bytes calldata
    )
        external
        returns (bool)
    {
        IERC20(token).forceApprove(msg.sender, amount + fee);
        IDepositThunderLoan(msg.sender).deposit(IERC20(token), amount + fee);
        return true;
    }
}

contract SecurityFixesTest is BaseTest {
    uint256 constant AMOUNT = 10e18;
    uint256 constant DEPOSIT_AMOUNT = AMOUNT * 100;
    address liquidityProvider = address(123);
    address user = address(456);

    function _allowAndDeposit(IERC20 token, uint256 amount) internal {
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(token, true);
        ERC20Mock(address(token)).mint(liquidityProvider, amount);
        vm.startPrank(liquidityProvider);
        token.approve(address(thunderLoan), amount);
        thunderLoan.deposit(token, amount);
        vm.stopPrank();
    }

    function testDepositDoesNotChangeExchangeRate() public {
        vm.prank(thunderLoan.owner());
        AssetToken asset = thunderLoan.setAllowedToken(tokenA, true);

        tokenA.mint(liquidityProvider, AMOUNT * 2);
        vm.startPrank(liquidityProvider);
        tokenA.approve(address(thunderLoan), AMOUNT * 2);
        thunderLoan.deposit(tokenA, AMOUNT);
        thunderLoan.deposit(tokenA, AMOUNT);
        vm.stopPrank();

        assertEq(asset.getExchangeRate(), asset.EXCHANGE_RATE_PRECISION());
    }

    function testUpgradePreservesStorageAndFee() public {
        _allowAndDeposit(tokenA, DEPOSIT_AMOUNT);
        uint256 feeBefore = thunderLoan.getFee();
        uint256 precisionBefore = thunderLoan.getFeePrecision();

        ThunderLoanUpgraded upgraded = new ThunderLoanUpgraded();
        thunderLoan.upgradeToAndCall(address(upgraded), "");

        assertEq(thunderLoan.getFee(), feeBefore);
        assertEq(thunderLoan.getFeePrecision(), precisionBefore);
        assertEq(
            address(thunderLoan.getAssetFromToken(tokenA)),
            address(ThunderLoanUpgraded(address(thunderLoan)).getAssetFromToken(tokenA))
        );

        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(thunderLoan));
        tokenA.mint(address(receiver), AMOUNT);
        thunderLoan.flashloan(address(receiver), tokenA, AMOUNT, "");
    }

    function testFeeIsCorrectForNon18DecimalToken() public {
        SixDecimalsMock usdc = new SixDecimalsMock();
        mockPoolFactory.createPool(address(usdc));
        vm.prank(thunderLoan.owner());
        thunderLoan.setAllowedToken(usdc, true);

        uint256 depositAmount = 1_000_000e6;
        usdc.mint(liquidityProvider, depositAmount);
        vm.startPrank(liquidityProvider);
        usdc.approve(address(thunderLoan), depositAmount);
        thunderLoan.deposit(usdc, depositAmount);
        vm.stopPrank();

        uint256 amount = 2000e6;
        uint256 fee = thunderLoan.getCalculatedFee(usdc, amount);
        assertEq(fee, (amount * thunderLoan.getFee()) / thunderLoan.getFeePrecision());
        assertEq(fee, 6e6);
    }

    function testCannotDepositDuringFlashLoan() public {
        _allowAndDeposit(tokenA, DEPOSIT_AMOUNT);
        DepositDuringFlashLoanReceiver receiver = new DepositDuringFlashLoanReceiver();
        tokenA.mint(address(receiver), AMOUNT);

        vm.expectRevert();
        thunderLoan.flashloan(address(receiver), tokenA, AMOUNT, "");
    }

    function testCannotRemoveTokenWithDeposits() public {
        _allowAndDeposit(tokenA, AMOUNT);
        vm.prank(thunderLoan.owner());
        vm.expectRevert();
        thunderLoan.setAllowedToken(tokenA, false);
    }

    function testZeroFeeFlashLoanDoesNotRevert() public {
        _allowAndDeposit(tokenA, DEPOSIT_AMOUNT);
        MockFlashLoanReceiver receiver = new MockFlashLoanReceiver(address(thunderLoan));
        tokenA.mint(address(receiver), AMOUNT);

        thunderLoan.flashloan(address(receiver), tokenA, 333, "");
        assertEq(thunderLoan.isCurrentlyFlashLoaning(tokenA), false);
    }

    function testFeeOnTransferDepositUsesReceivedAmount() public {
        FeeOnTransferMock feeToken = new FeeOnTransferMock();
        mockPoolFactory.createPool(address(feeToken));
        vm.prank(thunderLoan.owner());
        AssetToken asset = thunderLoan.setAllowedToken(feeToken, true);

        feeToken.mint(liquidityProvider, AMOUNT);
        vm.startPrank(liquidityProvider);
        feeToken.approve(address(thunderLoan), AMOUNT);
        thunderLoan.deposit(feeToken, AMOUNT);
        vm.stopPrank();

        assertEq(feeToken.balanceOf(address(asset)), AMOUNT - (AMOUNT / 100));
        assertEq(asset.balanceOf(liquidityProvider), AMOUNT - (AMOUNT / 100));
    }
}
