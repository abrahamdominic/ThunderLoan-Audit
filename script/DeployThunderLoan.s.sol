// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import { Script } from "forge-std/Script.sol";
import { ThunderLoan } from "../src/protocol/ThunderLoan.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract DeployThunderLoan is Script {
    function run() public {
        address poolFactory = vm.envAddress("POOL_FACTORY");

        vm.startBroadcast();
        ThunderLoan thunderLoan = new ThunderLoan();
        // Initialize atomically during proxy deployment so the proxy cannot be
        // front-run and initialized by an attacker.
        new ERC1967Proxy(address(thunderLoan), abi.encodeCall(ThunderLoan.initialize, (poolFactory)));
        vm.stopBroadcast();
    }
}
