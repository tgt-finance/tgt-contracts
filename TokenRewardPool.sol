// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/math/SafeMathUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/CountersUpgradeable.sol";

// preparation tasks
// 1. admin open the pool
// 2. admin set rewards_block_count
// 	(how many blocks that reward is applicable)
// 3. admin supply rewards
// 	-> calculate rewards_per_block
// 	(how much reward is given from pool to all staking users in 1 block = reward)
// 	-> calculate rewards_end_time
// 	(the last block that the pool gives reward)

// how it works
// for actions (supply reward, stake, withdraw, claim reward)
// - update pool rewards_accumulated_per_token
// (previous rewards_accumulated_per_token + ((now - last update block) * rewards_per_block) / staking_amount
// - update individual rewards_amount_withdrawable
// - update individual rewards_amount_paid

contract TokenRewardPool is OwnableUpgradeable, PausableUpgradeable, ReentrancyGuardUpgradeable {
    using SafeMathUpgradeable for uint256;
    using CountersUpgradeable for CountersUpgradeable.Counter;
    using SafeERC20Upgradeable for IERC20Upgradeable;

    struct PoolUser {
        // user staking amount
        uint256 stakingAmount;
        // reward amount available to withdraw
        uint256 rewardsAmountWithdrawable;
        // reward amount paid (also used to jot the past reward skipped)
        uint256 rewardsAmountPerStakingTokenPaid;
    }

    struct Pool {
        // staking token contract
        IERC20Upgradeable stakingToken;
        // reward token contract
        IERC20Upgradeable rewardsToken;
        // reward token distributor
        address rewardsDistributor;
        // total staking amount
        uint256 stakingAmount;
        // total reward amount available
        uint256 rewardsAmountAvailable;
        // total block numbers for the current distributing period
        // set by admin
        uint256 rewardsBlockCount;
        // reward end time
        uint256 rewardsEndBlock;
        // reward tokens to give to all pool users per block
        // calculated by rewardsEndBlock with rewardsBlockCount
        uint256 rewardsPerBlock;
        // from beginning until now, how much reward is given to 1 staking token
        uint256 rewardsAccumulatedPerStakingToken;
        // the reward last update block
        // it only changes in 2 situations
        // 1. depositReward
        // 2. updatePool modifier used in stake, withdraw, claimReward, depositReward
        uint256 rewardsLastCalculationBlock;
        // pool user mapping;
        mapping(address => PoolUser) users;
    }

    mapping(uint256 => Pool) public pools;
    CountersUpgradeable.Counter public poolIdTracker; // starts from 0

    uint256 public constant DENOMINATOR = 1e18;

    // initialize
    function initialize() public initializer {
        __Ownable_init();
        __Pausable_init();
        __ReentrancyGuard_init();
    }

    // admin step 1: createPool
    function createPool(
        IERC20Upgradeable _stakingToken,
        IERC20Upgradeable _rewardsToken,
        address _rewardsDistributor
    ) public onlyOwner {
        Pool storage pool = pools[poolIdTracker.current()];
        pool.stakingToken = _stakingToken;
        pool.rewardsToken = _rewardsToken;
        pool.rewardsDistributor = _rewardsDistributor;
        // to indicate the pool is activated
        pool.rewardsLastCalculationBlock = block.number;
        emit PoolCreated(
            poolIdTracker.current(),
            address(_stakingToken),
            address(_rewardsToken),
            _rewardsDistributor
        );
        poolIdTracker.increment();
    }

    // admin step 5: set duration
    // eg. use 15s as block time, 7 days = 7 * 24 * 60 * 60 / 15 = 40320
    function setPoolRewardsBlockCount(
        uint256 _poolId,
        uint256 _rewardsBlockCount
    ) external onlyOwner poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        // you need to finish one pool period before another one
        require(
            block.number >= pool.rewardsEndBlock,
            "Current pool end block not finished."
        );
        pool.rewardsBlockCount = _rewardsBlockCount;
        emit PoolRewardsBlockCountSet(_poolId, _rewardsBlockCount);
    }

    // admin step 6: set pool rewards distributor
    function setPoolRewardsDistributor(
        uint256 _poolId,
        address _rewardsDistributor
    ) external onlyOwner poolExists(_poolId) {
        require(_rewardsDistributor != address(0), "Invalid Input.");
        Pool storage pool = pools[_poolId];
        pool.rewardsDistributor = _rewardsDistributor;
        emit PoolRewardsDistributorSet(_poolId, _rewardsDistributor);
    }

    // admin step 7: supply reward (can only call by pool rewards distributor)
    function supplyRewards(uint256 _poolId, uint256 _rewardsTokenAmount)
        external
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, address(0));
        Pool storage pool = pools[_poolId];
        // check rewardsDistributor
        require(
            msg.sender == pool.rewardsDistributor,
            "Incorrect rewards distributor."
        );
        // check reward amount != 0
        require(
            _rewardsTokenAmount > 0,
            "Invalid input for rewards token amount."
        );
        // check current pool ended
        if (block.number >= pool.rewardsEndBlock) {
            // new or renewed pool
            // set up a new rate with new data
            // rewardsPerBlock = total reward / block number;
            pool.rewardsPerBlock = _rewardsTokenAmount.div(
                pool.rewardsBlockCount
            );
        } else {
            // existing pool
            // * caution
            // * cannot use the rewardsAmountAvailable to calculate directly because some rewards is not claimed
            // new total = (end block - current block) * rewardsPerBlock + rewards newly supplied
            // rewardsPerBlock = new total reward / block number;
            pool.rewardsPerBlock = (pool.rewardsEndBlock.sub(block.number))
                .mul(pool.rewardsPerBlock)
                .add(_rewardsTokenAmount)
                .div(pool.rewardsBlockCount);
        }
        pool.rewardsEndBlock = block.number.add(pool.rewardsBlockCount);
        pool.rewardsLastCalculationBlock = block.number;
        // transfer token
        pool.rewardsToken.safeTransferFrom(
            pool.rewardsDistributor,
            address(this),
            _rewardsTokenAmount
        );
        // update pool info
        pool.rewardsAmountAvailable = pool.rewardsAmountAvailable.add(
            _rewardsTokenAmount
        );
        emit PoolRewardSupplied(_poolId, _rewardsTokenAmount);
    }

    /* ========== USER METHODS ========== */

    // user stake
    function stake(uint256 _poolId, address _sender, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
        isAuthSender(_poolId)
    {
        require(_amount > 0, "Invalid input for amount.");

        updatePoolRewardInfo(_poolId, _sender);
        _claimReward(_poolId, _sender);
        _stakeOnly(_poolId, _sender, _amount);
    }

    function _stakeOnly(uint256 _poolId, address _sender, uint256 _amount)
        private
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_sender];
        pool.stakingAmount = pool.stakingAmount.add(_amount);
        poolUser.stakingAmount = poolUser.stakingAmount.add(_amount);
        emit PoolUserStaked(_poolId, _sender, _amount);
    }

    // user withdraw
    function withdraw(uint256 _poolId, address _sender, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
        isAuthSender(_poolId)
    {
        require(_amount > 0, "Invalid input for amount.");

        updatePoolRewardInfo(_poolId, _sender);
        _claimReward(_poolId, _sender);
        _withdrawOnly(_poolId, _sender, _amount);
    }

    function _withdrawOnly(uint256 _poolId, address _sender, uint256 _amount) private {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_sender];
        pool.stakingAmount = pool.stakingAmount.sub(_amount);
        poolUser.stakingAmount = poolUser.stakingAmount.sub(_amount);
        emit PoolUserWithdrawn(_poolId, _sender, _amount);
    }

    // user transfer the aibToken to another user
    function transfer(uint256 _poolId, address _sender, address _receiver, uint256 _amount)
        external
        nonReentrant
        poolExists(_poolId)
        isAuthSender(_poolId)
    {
        // handle sender state change
        updatePoolRewardInfo(_poolId, _sender);
        _claimReward(_poolId, _sender);
        _withdrawOnly(_poolId, _sender, _amount);

        // handle receiver state change, update recerver's state and claim reward for early staking
        updatePoolRewardInfo(_poolId, _receiver);
        // then stake and add _amount with early staking
        _stakeOnly(_poolId, _receiver, _amount);
    }

    // user claimReward
    function claimReward(uint256 _poolId, address _sender)
        external
        nonReentrant
        poolExists(_poolId)
    {
        updatePoolRewardInfo(_poolId, _sender);
        _claimReward(_poolId, _sender);
    }

    // user claimReward private
    function _claimReward(uint256 _poolId, address _sender) private poolExists(_poolId) {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_sender];
        uint256 rewardsAmountWithdrawable = poolUser.rewardsAmountWithdrawable;
        if (rewardsAmountWithdrawable > 0) {
            pool.rewardsAmountAvailable = pool.rewardsAmountAvailable.sub(
                rewardsAmountWithdrawable
            );
            emit PoolUserRewardClaimed(
                _poolId,
                _sender,
                rewardsAmountWithdrawable
            );
            poolUser.rewardsAmountWithdrawable = 0;
            pool.rewardsToken.safeTransfer(
                _sender,
                rewardsAmountWithdrawable
            );
        }
    }

    /* ========== HELPER METHODS ========== */

    // updatePoolReward
    function updatePoolRewardInfo(uint256 _poolId, address _userAddress) public {
        Pool storage pool = pools[_poolId];

        // update reward per token accumulated
        pool
            .rewardsAccumulatedPerStakingToken = getUpdatedRewardPerStakingTokenAccumulated(
            _poolId
        );

        // check if the current reward peroid is ended
        if (block.number < pool.rewardsEndBlock) {
            // if the pool is ongoing
            // update reward last calcuation time
            pool.rewardsLastCalculationBlock = block.number;
        } else {
            // update reward last calcuation time
            pool.rewardsLastCalculationBlock = pool.rewardsEndBlock;
        }

        if (_userAddress != address(0)) {
            PoolUser storage poolUser = pool.users[_userAddress];
            // update user.rewardsAmountWithdrawable
            // = rewardsAmountWithdrawable + new changes
            // = rewardsAmountWithdrawable + (staking amount * accumulated reward per token)
            uint stakeAmount = poolUser.stakingAmount.mul(pool.rewardsAccumulatedPerStakingToken.sub(poolUser.rewardsAmountPerStakingTokenPaid)).div(DENOMINATOR);
            poolUser.rewardsAmountWithdrawable = poolUser.rewardsAmountWithdrawable.add(stakeAmount);
            // as user rewardsAmountWithdrawable is updated, we need to reduct the current rewardsAccumulatedPerStakingToken
            poolUser.rewardsAmountPerStakingTokenPaid = pool.rewardsAccumulatedPerStakingToken;

            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingToken,
                _userAddress,
                poolUser.rewardsAmountWithdrawable,
                poolUser.rewardsAmountPerStakingTokenPaid
            );
        } else {
            emit PoolRewardInfoUpdated(
                _poolId,
                pool.rewardsLastCalculationBlock,
                pool.rewardsAccumulatedPerStakingToken,
                _userAddress,
                0,
                0
            );
        }
    }

    /* ========== VIEW METHODS ========== */

    // get updated reward per token
    // rewardsAccumulatedPerStakingToken + new changes from time = rewardsLastCalculationBlock
    function getUpdatedRewardPerStakingTokenAccumulated(uint256 _poolId)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        // no one is staking, just return
        if (pool.stakingAmount == 0) {
            return pool.rewardsAccumulatedPerStakingToken;
        }
        // check if the current reward peroid is ended
        if (block.number < pool.rewardsEndBlock) {
            // if the pool is ongoing
            // reward per token
            // = rewardsAccumulatedPerStakingToken + new changes
            // = rewardsAccumulatedPerStakingToken + ((now - last update) * rewards per block / staking amount)
            return
                pool.rewardsAccumulatedPerStakingToken.add(
                    block.number
                        .sub(pool.rewardsLastCalculationBlock)
                        .mul(pool.rewardsPerBlock)
                        .mul(DENOMINATOR)
                        .div(pool.stakingAmount)
                );
        }
        // if pool reward period is ended
        // reward per token
        // = rewardsAccumulatedPerStakingToken + new changes
        // = rewardsAccumulatedPerStakingToken + ((end time - last update) * rewards per block / staking amount)
        return
            pool.rewardsAccumulatedPerStakingToken.add(
                pool.rewardsEndBlock
                    .sub(pool.rewardsLastCalculationBlock)
                    .mul(pool.rewardsPerBlock)
                    .mul(DENOMINATOR)
                    .div(pool.stakingAmount)
            );
    }

    function getPoolUserEarned(uint256 _poolId, address _userAddress)
        public
        view
        returns (uint256)
    {
        Pool storage pool = pools[_poolId];
        PoolUser storage poolUser = pool.users[_userAddress];
        uint256 rewardsAccumulatedPerStakingToken = getUpdatedRewardPerStakingTokenAccumulated(_poolId);
        uint256 pendingReward = poolUser.stakingAmount.mul(
            rewardsAccumulatedPerStakingToken
            .sub(poolUser.rewardsAmountPerStakingTokenPaid)
        ).div(DENOMINATOR);

        uint256 reward = poolUser.rewardsAmountWithdrawable.add(pendingReward);
        return reward;
    }

    function getPoolUser(uint256 _poolId, address _userAddress)
        public
        view
        returns (PoolUser memory user)
    {
        Pool storage pool = pools[_poolId];
        user = pool.users[_userAddress];
    }

    /* ========== MODIFIERS ========== */

    modifier poolExists(uint256 _poolId) {
        Pool storage pool = pools[_poolId];
        require(pool.rewardsLastCalculationBlock > 0, "Pool doesn't exist.");
        _;
    }

    modifier isAuthSender(uint256 _poolId) {
        Pool storage pool = pools[_poolId];
        require(address(pool.stakingToken) == msg.sender, "no auth");
        _;
    }

    /* ========== EVENTS ========== */

    event PoolCreated(
        uint256 poolId,
        address stakingToken,
        address rewardToken,
        address rewardDistributor
    );
    event PoolRewardsBlockCountSet(uint256 poolId, uint256 rewardsBlockCount);
    event PoolRewardsDistributorSet(uint256 poolId, address rewardsDistributor);
    event PoolRewardSupplied(uint256 poolId, uint256 rewardsTokenAmount);

    event PoolUserStaked(uint256 poolId, address indexed user, uint256 amount);
    event PoolUserWithdrawn(
        uint256 poolId,
        address indexed user,
        uint256 amount
    );
    event PoolUserWithdrawnEmergency(
        uint256 poolId,
        address indexed user,
        uint256 amount
    );

    event PoolUserRewardClaimed(
        uint256 poolId,
        address indexed user,
        uint256 reward
    );

    event PoolRewardInfoUpdated(
        uint256 poolId,
        uint256 poolRewardsLastCalculationBlock,
        uint256 poolRewardsAccumulatedPerStakingToken,
        address poolUserAddress,
        uint256 poolUserRewardsAmountWithdrawable,
        uint256 poolUserRewardsAmountPerStakingTokenPaid
    );
}