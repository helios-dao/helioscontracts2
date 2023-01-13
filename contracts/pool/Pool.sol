// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

import "../interfaces/IPoolFactory.sol";
import "../interfaces/ILiquidityLockerFactory.sol";
import "../interfaces/ILiquidityLocker.sol";
import "../interfaces/IHeliosGlobals.sol";
import "../library/PoolLib.sol";
import "../token/PoolFDT.sol";

contract Pool is PoolFDT {
    using SafeMath  for uint256;
    using SafeMathUint for uint256;
    using SafeCast for uint256;
    using SafeERC20 for IERC20;


    address public immutable superFactory;
    address public immutable liquidityLocker;
    address public poolDelegate;
    IERC20  public immutable liquidityAsset;
    uint256 private immutable liquidityAssetDecimals;

    uint256 public principalOut;  // The sum of all outstanding principal on Loans.
    address public borrower;

    uint256 public lockupPeriod;
    uint256 public apy;
    uint256 public duration;
    uint256 public investmentPoolSize;
    uint256 public minInvestmentAmount;

    enum State {Initialized, Finalized, Deactivated}
    State public poolState;

    event PoolStateChanged(State state);
    event PoolAdminSet(address indexed poolAdmin, bool allowed);
    event BalanceUpdated(address indexed liquidityProvider, address indexed token, uint256 balance);
    event CoolDown(address indexed liquidityProvider, uint256 cooldown);
    event BorrowerSet(address indexed borrower);

    mapping(address => bool)        public poolAdmins;
    mapping(address => uint256)     public depositDate;

    constructor(
        address _poolDelegate,
        address _liquidityAsset,
        address _llFactory,
        uint256 _lockupPeriod,
        uint256 _apy,
        uint256 _duration,
        uint256 _investmentPoolSize,
        uint256 _minInvestmentAmount
    ) PoolFDT(PoolLib.NAME, PoolLib.SYMBOL){
        require(_liquidityAsset != address(0), "P:ZERO_LIQ_ASSET");
        require(_poolDelegate != address(0), "P:ZERO_POOL_DLG");
        require(_llFactory != address(0), "P:ZERO_LIQ_LOCKER_FACTORY");

        liquidityAsset = IERC20(_liquidityAsset);
        liquidityAssetDecimals = ERC20(_liquidityAsset).decimals();

        superFactory = msg.sender;
        poolDelegate = _poolDelegate;
        lockupPeriod = _lockupPeriod;
        apy = _apy;
        duration = _duration;
        investmentPoolSize = _investmentPoolSize;
        minInvestmentAmount = _minInvestmentAmount;
        poolState = State.Initialized;

        require(_globals(superFactory).isValidLiquidityAsset(_liquidityAsset), "P:INVALID_LIQ_ASSET");

        liquidityLocker = address(ILiquidityLockerFactory(_llFactory).newLocker(_liquidityAsset));

        emit PoolStateChanged(poolState);
    }

    function finalize() external {
        _isValidDelegateAndProtocolNotPaused();
        _isValidState(State.Initialized);
        poolState = State.Finalized;
        emit PoolStateChanged(poolState);
    }

    function deactivate() external {
        _isValidDelegateAndProtocolNotPaused();
        _isValidState(State.Finalized);
        poolState = State.Deactivated;
        emit PoolStateChanged(poolState);
    }

    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "P:NEG_DEPOSIT");
        require(_balanceOfLiquidityLocker().add(amount) <= investmentPoolSize, "P:DEP_AMT_EXCEEDS_POOL_SIZE");
        require(_balanceOfLiquidityLocker().add(amount) >= minInvestmentAmount, "P:DEP_AMT_BELOW_MIN");

        _whenProtocolNotPaused();
        _isValidState(State.Finalized);

        PoolLib.updateDepositDate(depositDate, balanceOf(msg.sender), amount, msg.sender);

        liquidityAsset.safeTransferFrom(msg.sender, liquidityLocker, amount);
        _mint(msg.sender, amount);

        _emitBalanceUpdatedEvent();
        emit CoolDown(msg.sender, uint256(0));
    }

    function withdraw(uint256 amount) external nonReentrant {
        _whenProtocolNotPaused();
        _canWithdraw(msg.sender, amount);

        // Burn the corresponding PoolFDTs balance.
        _burn(msg.sender, amount);

        withdrawFunds();
        // Transfer full entitled interest, decrement `interestSum`.
        _transferLiquidityLockerFunds(msg.sender, amount.sub(_recognizeLosses()));

        _emitBalanceUpdatedEvent();
    }

    function borrow(uint256 amount) external isBorrower {
        require(amount >= principalOut, "P:INSUFFICIENT_LIQUIDITY");

        principalOut = principalOut.add(amount);

        ILiquidityLocker(liquidityLocker).approve(msg.sender, amount);

        _transferLiquidityLockerFunds(msg.sender, amount);
    }

    function repay(uint256 principalClaim) external {
        require(principalClaim >= principalOut, "P:NOT_ENOUGH_TO_REPAY");

        uint256 interestClaim;

        interestClaim = interestClaim.add(principalClaim - principalOut);   // Distribute `principalClaim` overflow as interest to LPs.
        principalClaim = principalOut;                                      // Set `principalClaim` to `principalOut` so correct amount gets transferred.
        principalOut   = 0;                                                 // Set `principalOut` to zero to avoid subtraction overflow.

        interestSum = interestSum.add(interestClaim);

        _transferLiquidityAssetFrom(msg.sender, liquidityLocker, principalClaim.add(interestClaim));
        updateFundsReceived();
    }

    function decimals() public view override returns (uint8) {
        return uint8(liquidityAssetDecimals);
    }

    function withdrawFunds() public override {
        _whenProtocolNotPaused();
        uint256 withdrawableFunds = _prepareWithdraw();

        if (withdrawableFunds == uint256(0)) return;

        _transferLiquidityLockerFunds(msg.sender, withdrawableFunds);
        _emitBalanceUpdatedEvent();

        interestSum = interestSum.sub(withdrawableFunds);

        _updateFundsTokenBalance();
    }

    function setPoolAdmin(address poolAdmin, bool allowed) external {
        _isValidDelegateAndProtocolNotPaused();
        poolAdmins[poolAdmin] = allowed;
        emit PoolAdminSet(poolAdmin, allowed);
    }

    function setBorrower(address _borrower) external {
        _isValidDelegateAndProtocolNotPaused();
        borrower = _borrower;
        emit BorrowerSet(borrower);
    }

    function _canWithdraw(address account, uint256 amount) internal view {
        require(depositDate[account].add(lockupPeriod) <= block.timestamp, "P:FUNDS_LOCKED");
        require(_balanceOfLiquidityLocker() >= amount, "P:INSUFF_TRANS_BAL");
    }

    function _balanceOfLiquidityLocker() internal view returns (uint256) {
        return liquidityAsset.balanceOf(liquidityLocker);
    }

    function _isValidState(State _state) internal view {
        require(poolState == _state, "P:BAD_STATE");
    }

    function _globals(address poolFactory) internal view returns (IHeliosGlobals) {
        return IHeliosGlobals(IPoolFactory(poolFactory).globals());
    }

    function _emitBalanceUpdatedEvent() internal {
        emit BalanceUpdated(liquidityLocker, address(liquidityAsset), _balanceOfLiquidityLocker());
    }

    function _transferLiquidityAssetFrom(address from, address to, uint256 value) internal {
        liquidityAsset.safeTransferFrom(from, to, value);
    }

    function _whenProtocolNotPaused() internal view {
        require(!_globals(superFactory).protocolPaused(), "P:PROTO_PAUSED");
    }

    function _isValidDelegateAndProtocolNotPaused() internal view {
        require(msg.sender == poolDelegate, "P:NOT_DEL");
        _whenProtocolNotPaused();
    }

    function _transferLiquidityLockerFunds(address to, uint256 value) internal returns (bool){
        return ILiquidityLocker(liquidityLocker).transfer(to, value);
    }

    modifier isBorrower() {
        require(msg.sender == borrower, "P:NOT_BORROWER");
        _;
    }
}