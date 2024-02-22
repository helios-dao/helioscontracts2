pragma solidity 0.8.20;

import "forge-std/console.sol";

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {BlendedPool} from "../../contracts/pool/BlendedPool.sol";
import {MockTokenERC20} from "../mocks/MockTokenERC20.sol";

contract BlendedPoolTestHandler is CommonBase, StdCheats, StdUtils {
    address public constant OWNER_ADDRESS = 0x8A867fcC5a4d1FBbf7c1A9D6e5306b78511fDDDe;

    BlendedPool public blendedPool;
    MockTokenERC20 public assetElevated;
    ERC20 public asset;

    address[] public USER_ADDRESSES = [
    address(uint160(uint256(keccak256("user1")))),
    address(uint160(uint256(keccak256("user2")))),
    address(uint160(uint256(keccak256("user3")))),
    address(uint160(uint256(keccak256("user4")))),
    address(uint160(uint256(keccak256("user5"))))
    ];

    constructor(BlendedPool _blendedPool, MockTokenERC20 _assetElevated){
        blendedPool = _blendedPool;
        assetElevated = _assetElevated;
        asset = ERC20(assetElevated);
    }

    uint256 public netInflows;
    uint256 public netDeposits;

    /// Make a deposit for a user
    function deposit(uint256 amount, uint256 user_idx) public virtual {
        address user = pickUpUser(user_idx);

        amount = bound(amount, 1, type(uint80).max);

        if (asset.balanceOf(user) < amount) {
            assetElevated.mint(user, amount);
        }

        vm.prank(user);
        asset.approve(address(blendedPool), amount);
        vm.prank(user);
        blendedPool.deposit(amount);

        netInflows += amount;
        netDeposits += amount;
    }

    /// Withdraw deposit for a user
    function withdraw(uint256 amount, uint256 user_idx) external {
        address user = pickUpUserFromBlendedPool(user_idx);
        if (user == address(0)) return;

        vm.prank(user);
        uint256 unlocked = blendedPool.unlockedToWithdraw(user);
        if (unlocked == 0) return;

        unlocked = bound(amount, 1, unlocked);

        vm.prank(user);
        blendedPool.withdraw(unlocked);

        netInflows -= amount;
        netDeposits -= amount;
    }

    uint256 public netYieldAccrued;

    /// Withdraw yield for a user
    function withdrawYield(uint256 user_idx) external {
        address user = pickUpUser(user_idx);

        if (netYieldAccrued == 0) return;

        uint256 user_current_yield = blendedPool.yields(user);

        if (user_current_yield == 0) return;

        vm.prank(user);
        if (blendedPool.withdrawYield()) {
            // withdrawn
            netYieldAccrued -= user_current_yield;
        } else {
            // added to pending yields
        }
    }

    /*
    HANDLERS - Admin Workflow
    */

    uint256 public yieldPrecisionLoss;
    uint256 public maxPrecisionLossForYields;

    /// Distribute yields
    function distributeYield() external {
        if (blendedPool.getHoldersCount() == 0) return;

        uint256 startingSumYields = sumUserYields();

        console.log("startingSumYields %s", startingSumYields);

        uint256 newYieldToDistribute = 0.1e18;

        vm.prank(OWNER_ADDRESS);
        blendedPool.distributeYields(newYieldToDistribute);

        netYieldAccrued += newYieldToDistribute;

        console.log("netYieldAccrued %s", netYieldAccrued);

        uint256 actualChangeInUserYields = sumUserYields() - startingSumYields;

        console.log("actualChangeInUserYields %s", actualChangeInUserYields);
        yieldPrecisionLoss += newYieldToDistribute - actualChangeInUserYields;

        console.log("yieldPrecisionLoss %s", yieldPrecisionLoss);

        // The maximum precision loss for this distribution is the total number of depositors minus 1
        // example: if there are 50 depositors and the distribution is 100049, there is a precision loss of 49
        if (blendedPool.getHoldersCount() > 0)
            maxPrecisionLossForYields += blendedPool.getHoldersCount() - 1;

        console.log("maxPrecisionLossForYields %s", maxPrecisionLossForYields);
    }

    /// Finish pending withdrawal for a user
    function concludePendingWithdrawal(uint256 user_idx) external {
        address user = pickUpUser(user_idx);

        uint256 pendingWithdrawalAmount = blendedPool.pendingWithdrawals(user);

        vm.prank(OWNER_ADDRESS);
        blendedPool.concludePendingWithdrawal(user);

        netInflows -= pendingWithdrawalAmount;
        netDeposits -= pendingWithdrawalAmount;
    }

    /// Finish pending yield withdrawal for a user
    function concludePendingYield(uint256 user_idx) external {
        address user = pickUpUser(user_idx);
        uint256 pendingYieldAmount = blendedPool.pendingYields(user);
        vm.prank(OWNER_ADDRESS);
        blendedPool.concludePendingYield(user);
        netYieldAccrued -= pendingYieldAmount;
    }

    uint256 public netBorrowed;

    /// Borrow money from the deposits
    function borrow(uint256 amount) external {
        amount = bound(amount, 0, blendedPool.totalBalance());

        vm.prank(OWNER_ADDRESS);
        blendedPool.borrow(OWNER_ADDRESS, amount);
        netInflows -= amount;
        netBorrowed += amount;
    }

    /// Repay money to the pool
    function repay(uint256 amount) external {
        amount = bound(amount, 1, type(uint80).max);

        assetElevated.mint(OWNER_ADDRESS, amount);

        vm.prank(OWNER_ADDRESS);
        asset.approve(address(blendedPool), amount);

        vm.prank(OWNER_ADDRESS);
        blendedPool.repay(amount);

        netInflows += amount;
        if (amount > netBorrowed) {
            netBorrowed = 0;
        } else {
            netBorrowed -= amount;
        }
    }

    /// Time warp simulation
    function warp(uint256 timestamp) external {
        timestamp = bound(timestamp, 500, type(uint80).max);
        vm.warp(block.timestamp + timestamp);
    }

    function users() public view returns (address[] memory) {
        return USER_ADDRESSES;
    }

    function sumUserYields() public view returns (uint sum){
        sum = 0;
        for (uint i = 0; i < blendedPool.getHoldersCount(); i++) {
            address holder = blendedPool.getHolderByIndex(i);
            sum += blendedPool.yields(holder);
        }
    }

    function sumUserLockedTokens() public view returns (uint sum){
        sum = 0;
        for (uint i = 0; i < blendedPool.getHoldersCount(); i++) {
            address holder = blendedPool.getHolderByIndex(i);
            sum += blendedPool.balanceOf(holder) - blendedPool.unlockedToWithdraw(holder);
        }
    }

    function pickUpUser(uint256 user_idx) public view returns (address) {
        user_idx = user_idx % USER_ADDRESSES.length;
        return USER_ADDRESSES[user_idx];
    }

    function pickUpUserFromBlendedPool(uint256 user_idx) public view returns (address) {
        uint256 holderCount = blendedPool.getHoldersCount();
        if (holderCount == 0) return address(0);

        user_idx = bound(user_idx, 0, holderCount - 1);

        return blendedPool.getHolderByIndex(user_idx);
    }
}