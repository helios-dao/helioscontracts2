// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import {HeliosGlobals} from "../contracts/global/HeliosGlobals.sol";
import {PoolFactory} from "../contracts/pool/PoolFactory.sol";
import {HeliosUSD} from "../contracts/token/HeliosUSD.sol";
import {MockTokenERC20} from "../tests/mocks/MockTokenERC20.sol";

contract DeployScript is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address adminAddress = vm.envAddress("HELIOS_OWNER");

        vm.startBroadcast(deployerPrivateKey);

        HeliosGlobals heliosGlobals = new HeliosGlobals(adminAddress);
        PoolFactory poolFactory = new PoolFactory(address(heliosGlobals));
        HeliosUSD heliosUsd = new HeliosUSD(adminAddress);

        // Only for staging. Uncomment for staging
        // MockTokenERC20 mockTokenERC20 = new MockTokenERC20("mUSDC", "mUSDC");
        vm.stopBroadcast();

        console.log("HeliosGlobals %s", address(heliosGlobals));
        console.log("PoolFactory %s", address(poolFactory));
        console.log("Helios USD %s", address(heliosUsd));
    }
}