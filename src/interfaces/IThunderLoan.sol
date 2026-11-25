// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

// @audit-info the IThunderLoad contract should be implemented by the ThunderLoadLoan contract!
interface IThunderLoan {
    function repay(address token, uint256 amount) external;
}
