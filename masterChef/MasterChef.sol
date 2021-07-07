pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/IERC20.sol";
import "../common/MixinResolver.sol";
import "../token/EthCash.sol";
import "../interfaces/ISynthetic.sol";

// MasterChef is the master of ETHC. He can make ETHC and he is a fair guy.
//
// Note that it's ownable and the owner wields tremendous power. The ownership
// will be transferred to a governance smart contract once ETHC is sufficiently
// distributed and the community can show to govern itself.
//
// Have fun reading it. Hopefully it's bug-free. God bless.
contract MasterChef is Owned, MixinResolver {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 availableReward;
        //
        // We do some fancy math here. Basically, any point in time, the amount of ETHCs
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (user.amount * pool.accEthCPerShare) - user.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accEthCPerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }
    // Info of each pool.
    struct PoolInfo {
        uint256 allocPoint; // How many allocation points assigned to this pool. ETHCs to distribute per block.
        uint256 lastRewardBlock; // Last block number that ETHCs distribution occurs.
        uint256 accEthCPerShare; // Accumulated ETHCs per share, times 1e12. See below.
        uint256 totalAmount;
    }
    // The ETHC TOKEN!
    EthCash public ethCash;
    // Dev address.
    address public devaddr;
    // Block number when bonus ETHC period ends.
    uint256 public bonusEndBlock;
    // ETHC tokens created per block.
    uint256 public ethCPerBlock;
    // Bonus muliplier for early ETHC makers.
    uint256 public constant BONUS_MULTIPLIER = 10;
    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;
    // Total allocation poitns. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when ETHC mining starts.
    uint256 public startBlock;
    // for pool name get index  real index = index - 1.
    mapping(bytes32 => uint256) public poolHouse;
    //
    bytes32 private constant CONTRACT_SYNTHETIC = "Synthetic";
    event Add(address indexed user, uint256 indexed pid, uint256 amount);
    event Sub(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );

    constructor(
        EthCash _ethCash,
        address _resolver,
        address _devaddr,
        uint256 _ethCPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock
    ) Owned(msg.sender) MixinResolver(_resolver) public {
        ethCash = _ethCash;
        devaddr = _devaddr;
        ethCPerBlock = _ethCPerBlock;
        bonusEndBlock = _bonusEndBlock;
        startBlock = _startBlock;
    }

    function poolLength() public view returns (uint256) {
        return poolInfo.length;
    }

    function getUserInfo(bytes32 poolName, address _address) public view returns (uint256, uint256, uint256) {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;

        UserInfo memory info = userInfo[_pid][_address];
        return (info.amount, info.rewardDebt, info.availableReward);
    }

    function getPoolInfo(bytes32 poolName) external view returns (uint256, uint256, uint256, uint256) {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;

        PoolInfo memory info = poolInfo[_pid];
        return (info.totalAmount, info.allocPoint, info.lastRewardBlock, info.accEthCPerShare);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function addPool(
        bytes32 poolName,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 lastRewardBlock =
        block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(
            PoolInfo({
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accEthCPerShare: 0,
            totalAmount: 0
            })
        );
        poolHouse[poolName] = poolLength();
    }

    // Update the given pool's ETHC allocation point. Can only be called by the owner.
    function set(
        bytes32 poolName,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(
            _allocPoint
        );
        poolInfo[_pid].allocPoint = _allocPoint;
    }

    // Return reward multiplier over the given _from to _to block.
    function getMultiplier(uint256 _from, uint256 _to)
    public
    view
    returns (uint256)
    {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from).mul(BONUS_MULTIPLIER);
        } else if (_from >= bonusEndBlock) {
            return _to.sub(_from);
        } else {
            return
            bonusEndBlock.sub(_from).mul(BONUS_MULTIPLIER).add(
                _to.sub(bonusEndBlock)
            );
        }
    }

    // View function to see pending ETHCs on frontend.
    function pendingEthC(bytes32 poolName, address _user)
    external
    view
    returns (uint256)
    {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accEthCPerShare = pool.accEthCPerShare;
        uint256 lpSupply = pool.totalAmount;
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 multiplier =
            getMultiplier(pool.lastRewardBlock, block.number);
            uint256 ethCReward =
            multiplier.mul(ethCPerBlock).mul(pool.allocPoint).div(
                totalAllocPoint
            );
            accEthCPerShare = accEthCPerShare.add(
                ethCReward.mul(1e12).div(lpSupply)
            );
        }
        return user.amount.mul(accEthCPerShare).div(1e12).sub(user.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = pool.totalAmount;
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        uint256 multiplier = getMultiplier(pool.lastRewardBlock, block.number);
        uint256 ethCReward =
        multiplier.mul(ethCPerBlock).mul(pool.allocPoint).div(
            totalAllocPoint
        );

        ethCash.mint(address(this), ethCReward);
        pool.accEthCPerShare = pool.accEthCPerShare.add(
            ethCReward.mul(1e12).div(lpSupply)
        );
        pool.lastRewardBlock = block.number;
    }

    // add integral to MasterChef for ETHC allocation.
    function add(bytes32 poolName, address account, uint256 _amount) onlyPoolProxy(poolName) public {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][account];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 pending =
            user.amount.mul(pool.accEthCPerShare).div(1e12).sub(
                user.rewardDebt
            );
            user.availableReward = user.availableReward.add(pending);
        }
        user.amount = user.amount.add(_amount);
        pool.totalAmount = pool.totalAmount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accEthCPerShare).div(1e12);
        emit Add(account, _pid, _amount);
    }

    function sub(bytes32 poolName, address account, uint256 _amount) onlyPoolProxy(poolName) public {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][account];
        require(user.amount >= _amount, "sub amount: not good");
        updatePool(_pid);
        uint256 pending =
        user.amount.mul(pool.accEthCPerShare).div(1e12).sub(
            user.rewardDebt
        );
        user.availableReward = user.availableReward.add(pending);
        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accEthCPerShare).div(1e12);
        pool.totalAmount = pool.totalAmount.sub(_amount);
        emit Sub(account, _pid, _amount);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(bytes32 poolName, uint _amount) public {
        uint256 _pid = poolHouse[poolName];
        require(_pid > 0, "not found pool name in house");
        _pid = _pid - 1;

        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        uint256 pending =
        user.amount.mul(pool.accEthCPerShare).div(1e12).sub(
            user.rewardDebt
        );
        uint256 reward = user.availableReward.add(pending);
        require(reward >= _amount, "reward not good");
        safeEthCTransfer(msg.sender, _amount);
        // need fee 10%
        SyntheticAddress().chargeWithdrawFee(msg.sender, _amount);
        user.rewardDebt = user.amount.mul(pool.accEthCPerShare).div(1e12);
        user.availableReward = reward - _amount;
        emit Withdraw(msg.sender, _pid, reward);
    }

    // Safe ETHC transfer function, just in case if rounding error causes pool to not have enough ETHCs.
    function safeEthCTransfer(address _to, uint256 _amount) internal {
        uint256 ethCBal = ethCash.balanceOf(address(this));
        if (_amount > ethCBal) {
            ethCash.transfer(_to, ethCBal);
        } else {
            ethCash.transfer(_to, _amount);
        }
    }

    function mintEthC(bytes32 poolName, address _to, uint256 _amount) external onlyPoolProxy(poolName) {
        ethCash.mint(_to, _amount);
    }

    // Update dev address by the previous dev.
    function dev(address _devaddr) public {
        require(msg.sender == devaddr, "dev: wut?");
        devaddr = _devaddr;
    }

    modifier onlyPoolProxy(bytes32 currencyKey) {
        require(msg.sender == resolver.requireAndGetAddress(currencyKey, "Missing currencyKey address"), "Only authorized pool contract can perform this action");
        _;
    }

    function SyntheticAddress() internal view returns (ISynthetic) {
        return ISynthetic(resolver.requireAndGetAddress(CONTRACT_SYNTHETIC, "Missing Synthetic address"));
    }
}
