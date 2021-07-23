// SPDX-License-Identifier: BSD-3-Clause
pragma solidity >=0.4.22 <0.9.0;
import "./IterableMapping.sol";
import "./I_Token.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/VRFConsumerBase.sol";

contract MiningReward is VRFConsumerBase, Ownable {
    bytes32 internal keyHash;
    uint256 internal fee;
    uint256 public randomResult;

    using IterableMapping for IterableMapping.Map;
    IterableMapping.Map private joiner;

    mapping(bytes32 => bool) public randomnessUsed; // randomness is used or not
    uint256 BLOCK_INTERVAL = 4; // avg seconds between blocks
    uint256 BLOCK_DRAW = (60 / BLOCK_INTERVAL) * 60 * 1; // the block number pass when the lottery draw
    uint256 BLOCK_LOCK = (60 / BLOCK_INTERVAL) * 60 * 24; // the block number pass when the reward all release
    uint256 BLOCK_HALF = (60 / BLOCK_INTERVAL) * 60 * 24; // the block number pass when the reward become the half amount of the prev

    uint256 public BLOCK_INITIAL; // the block number when this contract deploy
    uint256 constant INITIAL_REWARD = 1560 * 1e16; // the initail amount of block reward, half every BLOCK_HALF time
    uint256 public constant STAKING_AMOUNT = 50 * 1e16; // the staking amount of balance that required to join lottery
    uint256 constant MIN_REWARD = 1 * 1e16; // minimum amount of block reward
    uint256 WINNER_PERCENT = 1; // the percentage of the joiner amount to win the lottery, multiply by 100

    bytes32 public requestId; // random number request id
    uint256 public lastRandomBlockNumber; // last block number to get randomness
    uint256 public lastOpenBlockNumber; // last block number to open lottery
    uint256[] public randomNumbers; // random numbers expand from randomness
    uint256[] public rangeNumbers; // random numbers transform to numbers between 0-(the size of the joiner list)
    address[] public winners; // winners of the last drawing
    address[] public queenNodes; // queen nodes of the last drawing
    uint256 public winnerNum; // how many winners in each drawing

    I_Token internal bxx_;

    struct Lock {
        uint256 amount;
        uint256 blockNumber; // block number when funds deposit
    }
    struct Stake {
        uint256 amount;
        uint256 blockNumber; // block number when funds deposit
        bool unlock;
    }

    mapping(address => Lock[]) public _balances; // all winners balance of each drawing
    mapping(address => Stake) public _staking; // all joiners staking info

    event RandomnessFulfill(
        uint256 indexed randomness,
        bytes32 indexed requestID
    );
    event Empty(string indexed name);
    event OpenLottery(uint256 indexed perWinnerReward);
    event CleanJoiner(address indexed name);
    event WinReward(address indexed winner, uint256 indexed perWinnerReward);

    event JoinLottery(address indexed beneficiary, address indexed issuer);

    constructor(address _bxx)
        VRFConsumerBase(
            0xdD3782915140c8f3b190B5D67eAc6dc5760C46E9, // VRF Coordinator
            0xa36085F69e2889c224210F603D836748e7dC0088 // LINK Token
        )
    {
        keyHash = 0x6c3699283bda56ad74f6b855546325b68d482e983852a7a82979cc4807b641f4;
        fee = 0.1 * 10**18; // 0.1 LINK (Varies by network)

        lastRandomBlockNumber = block.number;
        lastOpenBlockNumber = block.number;
        BLOCK_INITIAL = block.number;

        bxx_ = I_Token(_bxx);
    }

    /**
     * @notice Join the lottery to win reward
     * @param beneficiary The beneficiary to which cheques were assigned. Beneficiary must be an Externally Owned Account
     * @param issuer The issuer of cheques from the chequebook. Issuer is an Externally Owned Account
     */
    function join(address beneficiary, address issuer) public {
        require(staking(), "staking failed");

        joiner.add(beneficiary, issuer);
        emit JoinLottery(beneficiary, issuer);
        open();
    }

    /**
     * @notice staking Transfer in if not staking, to join the lottery, must staking STAKING_AMOUNT of the token
     */
    function staking() private returns (bool) {
        if (getStakingAmount(msg.sender) < STAKING_AMOUNT) {
            bxx_.transferFrom(msg.sender, address(this), STAKING_AMOUNT);
            _staking[msg.sender].amount = STAKING_AMOUNT;
            _staking[msg.sender].blockNumber = block.number;
            _staking[msg.sender].unlock = false;
        }
        return true;
    }

    /**
     * @notice getStakingAmount Get staking amount of the owner
     * @return The amount of bxx token
     */
    function getStakingAmount(address owner) public view returns (uint256) {
        if (_staking[owner].unlock) {
            return 0;
        }
        return _staking[owner].amount;
    }

    /**
     * @notice unlockStaking unlock the staking token, and set the block number which is the start point to release the token
     */
    function unlockStaking() external {
        _staking[msg.sender].unlock = true;
        _staking[msg.sender].blockNumber = block.number;
    }

    /**
     * @notice getStakingUnlockAmount Get the unlock amount of staking token
     * @return amount The unlock amount of bxx token
     */
    function getStakingUnlockAmount(address owner)
        public
        view
        returns (uint256 amount)
    {
        if (_staking[owner].unlock == false) {
            return 0;
        }
        uint256 deltaBlock = block.number - _staking[owner].blockNumber;
        uint256 pcnt = (deltaBlock * 100) / BLOCK_LOCK;
        pcnt = min(pcnt, 100);
        amount = (pcnt * _staking[owner].amount) / 100;
        return amount;
    }

    /**
     * @notice open Draw the lottery by oracle randomness or distribute the reward by the given randomness
     */
    function open() public {
        if (randomResult != 0 && randomnessUsed[requestId] == false) {
            distribute();
            lastOpenBlockNumber = block.number;
        } else if (block.number - lastRandomBlockNumber >= BLOCK_DRAW) {
            requestId = getRandomNumber();
            lastRandomBlockNumber = block.number;
        } else {
            emit Empty("nothing happened");
        }
    }

    /**
     * @notice distribute Draw the lottery by oracle randomness or distribute the reward by the given randomness
     */
    function distribute() private {
        require(requestId != 0, "request randomness first");
        require(randomnessUsed[requestId] == false, "already opened");
        randomnessUsed[requestId] = true;

        genRangeNumbers();
        genQueenNodes();
        genWinners();
        uint256 perWinnerReward = getPerWinnerReward();

        for (uint256 i = 0; i < winners.length; i++) {
            Lock memory lock;
            lock.blockNumber = block.number;
            lock.amount = perWinnerReward;
            _balances[winners[i]].push(lock);
            emit WinReward(winners[i], perWinnerReward);
        }
        cleanJoiners();
        emit OpenLottery(perWinnerReward);
    }

    /**
     * @notice cleanJoiners Clean the joiner list to aviod repeated participation in the lottery
     */
    function cleanJoiners() private {
        for (uint256 i = 0; i < joiner.size(); i++) {
            address key = joiner.getKeyAtIndex(i);
            joiner.remove(key);
            emit CleanJoiner(key);
        }
    }

    /**
     * @notice genRangeNumbers Generate numbers between 0-(size of the joiner list)
     */
    function genRangeNumbers() private {
        genRandomNumbers();
        uint256 size = joiner.size();
        rangeNumbers = getRangeNumbers(randomNumbers, size);
    }

    /**
     * @notice genRandomNumbers Expand random numbers
     */
    function genRandomNumbers() private {
        winnerNum = getWinnerNum();
        randomNumbers = expand(randomResult, winnerNum);
    }

    /**
     * @notice removeJoiner Just for the admin to test, will be removed in the mainnet
     */
    function removeJoiner(address key) public onlyOwner {
        joiner.remove(key);
    }

    /**
     * @notice setWinnerPercent Just for the admin to test, will be removed in the mainnet
     */
    function setWinnerPercent(uint256 percent) public onlyOwner {
        WINNER_PERCENT = percent;
    }

    /**
     * @notice getWinnerNum Calc the winner amount
     */
    function getWinnerNum() public view returns (uint256) {
        uint256 size = joiner.size();
        uint256 num = WINNER_PERCENT * size;
        num = max(num, 100);
        num = num / 100;
        return num;
    }

    /**
     * @notice expand Expand the randomness to a list of random values
     */
    function expand(uint256 randomValue, uint256 n)
        public
        pure
        returns (uint256[] memory expandedValues)
    {
        expandedValues = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            expandedValues[i] = uint256(keccak256(abi.encode(randomValue, i)));
        }
        return expandedValues;
    }

    /**
     * @notice genQueenNodes Generate queen nodes to select winners
     */
    function genQueenNodes() private {
        queenNodes = getQueenNodes();
    }

    function getJoinerSize() public view returns (uint256) {
        return joiner.size();
    }

    function getJoinerIssuers(address key)
        public
        view
        returns (address[] memory)
    {
        return joiner.get(key);
    }

    function getJoinerIndexOf(address key) public view returns (uint256) {
        return joiner.getIndexOf(key);
    }

    function getJoinerInserted(address key) public view returns (bool) {
        return joiner.getInserted(key);
    }

    function getJoiners() public view returns (address[] memory) {
        return joiner.getKeys();
    }

    function getIssuerLength(address beneficiary)
        public
        view
        returns (uint256)
    {
        return joiner.get(beneficiary).length;
    }

    function getKeyAt(uint256 i) public view returns (address) {
        return joiner.getKeyAtIndex(rangeNumbers[i]);
    }

    function getRangeNumbersLength() public view returns (uint256) {
        return rangeNumbers.length;
    }

    function getWinnersLength() public view returns (uint256) {
        return winners.length;
    }

    /**
     * @notice Get queen nodes from range numbers
     * @return Queens is queen nodes address list
     */
    function getQueenNodes() public view returns (address[] memory) {
        uint256 n = rangeNumbers.length;
        address[] memory queens = new address[](n);
        for (uint256 i = 0; i < rangeNumbers.length; i++) {
            queens[i] = getKeyAt(i);
        }
        return queens;
    }

    /**
     * @notice genWinners Get winner list of the last lottery
     */
    function genWinners() private {
        delete winners;
        uint256 n = queenNodes.length;
        for (uint256 i = 0; i < n; i++) {
            for (uint256 j = 0; j < joiner.get(queenNodes[i]).length; j++) {
                winners.push(joiner.get(queenNodes[i])[j]);
            }
        }
    }

    /**
     * @notice getPerWinnerReward Get current block reward for each winner
     */
    function getPerWinnerReward() public view returns (uint256) {
        return getCurrentReward() / winners.length;
    }

    /**
     * @notice getCurrentReward Get current cumulative amount of reward that will distribute to all winners
     */
    function getCurrentReward() public view returns (uint256) {
        require(winners.length > 0, "no winners found");
        uint256 blockReward = getCurrentBlockReward();
        uint256 multiplier = (block.number - lastOpenBlockNumber) / BLOCK_DRAW;

        return blockReward * multiplier;
    }

    /**
     * @notice getCurrentBlockReward Get current block reward
     */
    function getCurrentBlockReward() public view returns (uint256) {
        uint256 delta = block.number - BLOCK_INITIAL;
        uint256 power = delta / BLOCK_HALF;
        uint256 current_reward = (INITIAL_REWARD * 5**power) / 10**power; // half every BLOCK_HALF time
        current_reward = max(MIN_REWARD, current_reward);
        return current_reward;
    }

    /**
     * @notice getRangeNumbers Get range numbers
     */
    function getRangeNumbers(uint256[] memory _randomNumbers, uint256 size)
        public
        pure
        returns (uint256[] memory)
    {
        uint256 n = _randomNumbers.length;
        uint256[] memory _rangeNumbers = new uint256[](n);
        for (uint256 i = 0; i < n; i++) {
            _rangeNumbers[i] = _randomNumbers[i] % size;
        }
        return _rangeNumbers;
    }

    /**
     * @notice getRewardUnlockAmount Get lottery reward unlock amount of owner
     */
    function getRewardUnlockAmount(address owner)
        public
        view
        returns (uint256 amount)
    {
        for (uint256 i = 0; i < _balances[owner].length; i++) {
            uint256 deltaBlock = block.number - _balances[owner][i].blockNumber;
            uint256 pcnt = (deltaBlock * 100) / BLOCK_LOCK;
            pcnt = min(pcnt, 100);
            amount = amount + ((pcnt * _balances[owner][i].amount) / 100);
        }
        return amount;
    }

    /**
     * @notice getRewardAmount Get lottery reward amount
     */
    function getRewardAmount(address owner)
        public
        view
        returns (uint256 amount)
    {
        for (uint256 i = 0; i < _balances[owner].length; i++) {
            amount = amount + _balances[owner][i].amount;
        }
        return amount;
    }

    function max(uint256 a, uint256 b) public pure returns (uint256) {
        return a > b ? a : b;
    }

    function min(uint256 a, uint256 b) public pure returns (uint256) {
        return a < b ? a : b;
    }

    /**
     * @notice withdraw Both withdraw the lottery reward and the staking
     */
    function withdraw() public {
        uint256 rewardAmount = getRewardUnlockAmount(msg.sender);
        uint256 stakingAmount = getStakingUnlockAmount(msg.sender);
        uint256 totalAmount = rewardAmount + stakingAmount;
        bxx_.transfer(msg.sender, totalAmount);
    }

    /**
     * @notice getRandomNumber Requests randomness
     */
    function getRandomNumber() private returns (bytes32) {
        require(
            LINK.balanceOf(address(this)) >= fee,
            "Not enough LINK - fill contract with faucet"
        );
        return requestRandomness(keyHash, fee);
    }

    /**
     * @notice fulfillRandomness Callback function used by VRF Coordinator
     */
    function fulfillRandomness(bytes32 _requestId, uint256 randomness)
        internal
        override
    {
        require(_requestId == requestId, "random req id mismatch");
        randomResult = randomness;
        emit RandomnessFulfill(randomness, _requestId);
    }

    /**
     * @notice sweepToken Just for the admin to test, will be removed in the mainnet
     */
    function sweepToken(IERC20 token) external onlyOwner {
        token.transfer(owner(), token.balanceOf(address(this)));
    }
}
