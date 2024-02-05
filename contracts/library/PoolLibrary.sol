// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

library PoolLibrary {
    enum State {
        Initialized,
        Finalized,
        Deactivated
    }

    struct PoolInfo {
        uint256 lockupPeriod;
        uint256 apy;
        uint256 duration;
        uint256 investmentPoolSize;
        uint256 minInvestmentAmount;
        uint256 withdrawThreshold;
    }

    struct DepositInstance {
        IERC20 token;
        uint256 amount;
        uint256 unlockTime;
    }
}