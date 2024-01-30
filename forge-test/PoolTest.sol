pragma solidity 0.8.16;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import {MockTokenERC20} from "./mocks/MockTokenERC20.sol";
import {HeliosGlobals} from "../contracts/global/HeliosGlobals.sol";
import {AbstractPool} from "../contracts/pool/AbstractPool.sol";
import {Pool} from "../contracts/pool/Pool.sol";
import {BlendedPool} from "../contracts/pool/BlendedPool.sol";

import {FixtureContract} from "./fixtures/FixtureContract.sol";

contract BlendedPoolTest is Test, FixtureContract {
    event PendingReward(address indexed recipient, uint256 indexed amount);
    event WithdrawalOverThreshold(address indexed caller, uint256 indexed amount);

    function setUp() public {
        fixture();
        vm.prank(OWNER_ADDRESS);
        liquidityAsset.increaseAllowance(address(blendedPool), 1000);
        vm.stopPrank();
        vm.prank(USER_ADDRESS);
        liquidityAsset.increaseAllowance(address(blendedPool), 1000);
        vm.stopPrank();
    }

    /// @notice Test attempt to deposit; checking if variables are updated correctly
    function test_depositSuccess(address user1, address user2) external {
        createInvestorAndMintLiquidityAsset(user1, 1000);
        createInvestorAndMintLiquidityAsset(user2, 1000);
        vm.assume(user1 != user2);

        vm.startPrank(user1);

        //testing initial condition i.e. zeroes
        assertEq(blendedPool.balanceOf(user1), 0);
        assertEq(blendedPool.totalLA(), 0);
        assertEq(blendedPool.totalDeposited(), 0);

        uint256 user1Deposit = 100;
        liquidityAsset.increaseAllowance(address(blendedPool), user1Deposit);
        blendedPool.deposit(user1Deposit);

        //user's LP balance should be 100 now
        assertEq(blendedPool.balanceOf(user1), user1Deposit, "wrong LP balance for user1");

        //pool's total LA balance should be user1Deposit now
        assertEq(blendedPool.totalLA(), user1Deposit, "wrong LA balance after user1 deposit");

        //pool's total minted should also be user1Deposit
        assertEq(blendedPool.totalDeposited(), user1Deposit, "wrong totalDeposit after user1 deposit");
        vm.stopPrank();

        //now let's test for user2
        vm.startPrank(user2);
        assertEq(blendedPool.balanceOf(user2), 0, "user2 shouldn't have >0 atm");
        uint256 user2Deposit = 101;

        liquidityAsset.increaseAllowance(address(blendedPool), user2Deposit);
        blendedPool.deposit(user2Deposit);

        assertEq(blendedPool.balanceOf(user2), user2Deposit, "wrong user2 LP balance");

        //pool's total LA balance should be user1Deposit now
        assertEq(blendedPool.totalLA(), user1Deposit + user2Deposit, "wrong totalLA after user2");

        //pool's total minted should also be user1Deposit
        assertEq(blendedPool.totalDeposited(), user1Deposit + user2Deposit, "wrong totalDeposited after user2");
        vm.stopPrank();
    }

    /// @notice Test attempt to deposit below minimum
    function test_depositFailure(address user) external {
        vm.startPrank(user);
        uint256 depositAmountBelowMin = 1;
        vm.expectRevert("P:DEP_AMT_BELOW_MIN");
        blendedPool.deposit(depositAmountBelowMin);
    }

    /// @notice Test attempt to withdraw; both happy and unhappy paths
    function test_withdraw(address user) external {
        createInvestorAndMintLiquidityAsset(user, 1000);

        vm.startPrank(user);
        uint256 depositAmount = 150;
        uint256 currentTime = block.timestamp;

        liquidityAsset.increaseAllowance(address(blendedPool), depositAmount);
        //the user can withdraw the sum he has deposited earlier
        blendedPool.deposit(depositAmount);

        //attempt to withdraw too early fails
        vm.expectRevert("P:TOKENS_LOCKED");
        uint16[] memory indices = new uint16[](1);
        indices[0] = 0;
        uint256[] memory amounts = new uint256[](1);
        amounts[0] = depositAmount;
        blendedPool.withdraw(amounts, indices);

        vm.warp(currentTime + 1000);
        blendedPool.withdraw(amounts, indices);

        // but he cannot withdraw more
        // vm.expectRevert("P:INSUFFICIENT_BALANCE");
        // blendedPool.withdraw(1, indices);

        vm.stopPrank();
    }

    /// @notice Test complete scenario of depositing, distribution of rewards and claim
    function test_distributeRewardsAndClaim(address user1, address user2) external {
        createInvestorAndMintLiquidityAsset(user1, 1000);
        createInvestorAndMintLiquidityAsset(user2, 1000);
        vm.assume(user1 != user2);

        //firstly the users need to deposit before withdrawing
        uint256 user1Deposit = 100;
        vm.startPrank(user1);
        liquidityAsset.increaseAllowance(address(blendedPool), user1Deposit);
        blendedPool.deposit(user1Deposit);
        vm.stopPrank();

        uint256 user2Deposit = 1000;
        vm.startPrank(user2);
        liquidityAsset.increaseAllowance(address(blendedPool), user2Deposit);
        blendedPool.deposit(user2Deposit);
        vm.stopPrank();

        address[] memory holders = new address[](2);
        holders[0] = user1;
        holders[1] = user2;

        //a non-pool-admin address shouldn't be able to call distributeRewards()
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        blendedPool.distributeRewards(1000, holders);

        //only the pool admin can call distributeRewards()
        address poolAdmin = blendedPool.owner();
        vm.prank(poolAdmin);
        blendedPool.distributeRewards(1000, holders);

        //now we need to test if the users got assigned the correct rewards
        uint256 user1Rewards = blendedPool.rewards(user1);
        uint256 user2Rewards = blendedPool.rewards(user2);
        assertEq(user1Rewards, 90, "wrong reward user1");
        assertEq(user2Rewards, 909, "wrong reward user2"); //NOTE: 1 is lost as a dust value :(

        uint256 user1BalanceBefore = liquidityAsset.balanceOf(user1);
        vm.prank(user1);
        blendedPool.claimReward();
        assertEq(
            liquidityAsset.balanceOf(user1) - user1BalanceBefore,
            90,
            "user1 balance not upd after claimReward()"
        );

        uint256 user2BalanceBefore = liquidityAsset.balanceOf(user2);
        vm.prank(user2);
        blendedPool.claimReward();
        assertEq(
            liquidityAsset.balanceOf(user2) - user2BalanceBefore,
            909,
            "user2 balance not upd after claimReward()"
        );
    }

    /// @notice Test complete scenario of depositing, distribution of rewards and claim
    function test_distributeRewardsAndClaimRegPool(address user1, address user2) external {
        createInvestorAndMintLiquidityAsset(user1, 1000);
        createInvestorAndMintLiquidityAsset(user2, 1000);
        vm.assume(user1 != user2);

        //firstly the users need to deposit before withdrawing
        address poolAddress = mockPoolFactory.createPool(
            "1",
            address(liquidityAsset),
            address(liquidityLockerFactory),
            2000,
            10,
            1000,
            100000,
            100,
            500,
            1000
        );

        Pool pool = Pool(poolAddress);
        uint256 user1Deposit = 100;
        vm.startPrank(user1);
        liquidityAsset.increaseAllowance(poolAddress, 10000);
        pool.deposit(user1Deposit);
        vm.stopPrank();

        uint256 user2Deposit = 1000;
        vm.startPrank(user2);
        liquidityAsset.increaseAllowance(poolAddress, 10000);
        pool.deposit(user2Deposit);
        vm.stopPrank();

        address[] memory holders = new address[](2);
        holders[0] = user1;
        holders[1] = user2;

        //a non-pool-admin address shouldn't be able to call distributeRewards()
        vm.prank(user1);
        vm.expectRevert("Ownable: caller is not the owner");
        pool.distributeRewards(1000, holders);

        //only the pool admin can call distributeRewards()
        address poolAdmin = pool.owner();
        vm.prank(poolAdmin);
        pool.distributeRewards(1000, holders);

        //now we need to test if the users got assigned the correct rewards
        uint256 user1Rewards = pool.rewards(user1);
        uint256 user2Rewards = pool.rewards(user2);
        assertEq(user1Rewards, 1, "wrong reward user1");
        assertEq(user2Rewards, 10, "wrong reward user2"); //NOTE: 1 is lost as a dust value :(

        uint256 user1BalanceBefore = liquidityAsset.balanceOf(user1);
        vm.prank(user1);
        pool.claimReward();
        assertEq(
            liquidityAsset.balanceOf(user1) - user1BalanceBefore, 1, "user1 balance not upd after claimReward()"
        );

        uint256 user2BalanceBefore = liquidityAsset.balanceOf(user2);
        vm.prank(user2);
        pool.claimReward();
        assertEq(
            liquidityAsset.balanceOf(user2) - user2BalanceBefore,
            10,
            "user2 balance not upd after claimReward()"
        );
    }

    /// @notice Test scenario when there are not enough funds on the pool
    function test_insufficientFundsClaimReward(address user) external {
        createInvestorAndMintLiquidityAsset(user, 1000);

        //firstly the users need to deposit before withdrawing
        uint256 user1Deposit = 100;
        vm.startPrank(user);
        liquidityAsset.increaseAllowance(address(blendedPool), 10000);
        blendedPool.deposit(user1Deposit);
        vm.stopPrank();

        address[] memory holders = new address[](1);
        holders[0] = user;

        //only the pool admin can call distributeRewards()
        address poolAdmin = blendedPool.owner();
        vm.prank(poolAdmin);
        blendedPool.distributeRewards(1000, holders);

        assertEq(blendedPool.rewards(user), 1000, "rewards should be 1000 atm");

        // now let's deplete the pool's balance
        vm.prank(poolAdmin);
        uint256 drawdownAmount = blendedPool.totalSupply() - blendedPool.principalOut();
        blendedPool.drawdown(poolAdmin, drawdownAmount);

        //..and claim rewards as user1
        vm.startPrank(user);
        vm.expectEmit(false, false, false, false);
        // The expected event signature
        emit PendingReward(user, 1000);
        assertFalse(blendedPool.claimReward(), "should return false if not enough LA");

        vm.stopPrank();

        assertEq(blendedPool.rewards(user), 0, "rewards should be 0 after claim attempt");

        assertEq(blendedPool.pendingRewards(user), 1000, "pending rewards should be 1000 after claim attempt");

        uint256 user1BalanceBefore = liquidityAsset.balanceOf(user);

        mintLiquidityAsset(poolAdmin, 1000);
        vm.startPrank(poolAdmin);
        liquidityAsset.increaseAllowance(address(blendedPool), 1000);
        blendedPool.adminDeposit(999);
        blendedPool.concludePendingReward(user);

        uint256 user1BalanceAfter = liquidityAsset.balanceOf(user);

        //checking if the user got his money now
        assertEq(user1BalanceAfter, user1BalanceBefore + 1000, "invalid user1 LA balance after concluding");
    }

    function test_subsidingRegPoolWithBlendedPool(address user) external {
        createInvestorAndMintLiquidityAsset(user, 1000);
        vm.prank(user);
        address poolAddress = mockPoolFactory.createPool(
            "1", address(liquidityAsset), address(liquidityLockerFactory), 2000, 10, 1000, 1000, 100, 500, 1000
        );

        Pool pool = Pool(poolAddress);
        vm.startPrank(pool.owner());
        pool.setBlendedPool(address(blendedPool));
        vm.stopPrank();

        //a user deposits some LA to the RegPool
        vm.startPrank(user);
        liquidityAsset.increaseAllowance(poolAddress, 1000);
        pool.deposit(500);
        vm.stopPrank();

        //the admin distributes rewards and takes all the LA, emptying the pool
        vm.startPrank(pool.owner());

        address[] memory holders = new address[](1);
        holders[0] = user;
        pool.distributeRewards(100, holders);
        pool.drawdown(pool.owner(), 100);
        vm.stopPrank();

        //now let's deposit LA to the blended pool
        address bpOwner = blendedPool.owner();
        vm.startPrank(bpOwner);
        blendedPool.addPool(poolAddress);
        mintLiquidityAsset(bpOwner, 100);
        liquidityAsset.increaseAllowance(address(blendedPool), 100);
        blendedPool.adminDeposit(100);
        vm.stopPrank();

        //now let's claim reward. The blended pool will help
        vm.startPrank(user);
        liquidityAsset.increaseAllowance(poolAddress, 10000);
        pool.claimReward();
    }

    function test_maxPoolSize(address user, uint256 _maxPoolSize) external {
        createInvestorAndMintLiquidityAsset(user, 1000);

        _maxPoolSize = bound(_maxPoolSize, 1, 1e36);
        address poolAddress = mockPoolFactory.createPool(
            "1",
            address(liquidityAsset),
            address(liquidityLockerFactory),
            2000,
            10,
            1000,
            _maxPoolSize,
            0,
            500,
            1000
        );

        Pool pool = Pool(poolAddress);

        vm.startPrank(user);
        liquidityAsset.increaseAllowance(poolAddress, 1000);
        vm.expectRevert("P:MAX_POOL_SIZE_REACHED");
        pool.deposit(_maxPoolSize + 1);
        vm.stopPrank();
    }

    function test_reinvest(address user) external {
        createInvestorAndMintLiquidityAsset(user, 1000);

        //firstly the user needs to deposit
        uint256 user1Deposit = 100;
        vm.startPrank(user);
        liquidityAsset.increaseAllowance(address(blendedPool), 10000);
        blendedPool.deposit(user1Deposit);
        vm.stopPrank();

        address[] memory holders = new address[](1);
        holders[0] = user;

        //only the pool admin can call distributeRewards()
        address poolAdmin = blendedPool.owner();
        vm.prank(poolAdmin);
        blendedPool.distributeRewards(1000, holders);

        mintLiquidityAsset(blendedPool.getLL(), 1003);
        //liquidityAssetElevated.mint(blendedPool.getLL(), 1003);

        //now the user wishes to reinvest
        uint256 laBalancePool = liquidityAsset.balanceOf(blendedPool.getLL());
        uint256 userRewards = blendedPool.rewards(user);
        vm.startPrank(user);
        blendedPool.reinvest(1000);
        uint256 userBalanceNow = blendedPool.balanceOf(user);
        uint256 expected = user1Deposit + userRewards;
        assertEq(userBalanceNow, expected);
    }
}
