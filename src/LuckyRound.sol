// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "chainlink/vrf/dev/VRFCoordinatorV2_5.sol";
import "chainlink/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "./shared/CoreInterface.sol";
import "./shared/games/GameInterface.sol";
import "./LuckyRoundBet.sol";

/**
 * Errors used in this contract
 *
 * L01 - invalid staking contract
 * L02 - player address mismatch
 * L03 - amount mismatch
 * L04 - round mismatch
 * L05 - amount too low
 * L06 - new amount out of range
 * L07 - round is full
 * L08 - round already distributed
 * L09 - round not finished
 * L10 - round already requested
 * L11 - round is empty
 * L12 - round is not finished,
 * L13 - only core can place bets
 * L14 - error when tranfering tokens
 */
contract LuckyRound is
    AccessControl,
    GameInterface,
    VRFConsumerBaseV2Plus,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");
    bytes32 public constant SERVICE = keccak256("SERVICE");
    uint256 public constant ROUND_DURATION = 1 days;
    uint256 public constant BETS_LIMIT = 1000;
    uint256 public constant BONUS = 5_00;

    uint256 public MIN_BET_AMOUNT = 1000 ether;

    uint256 public immutable created;
    address public immutable core;
    address public immutable token;
    address public immutable staking;

    uint256 private immutable subscriptionId;
    address public immutable vrfCoordinator;
    bytes32 public immutable keyHash;

    uint32 private constant callbackGasLimit = 2_500_000;
    uint16 public constant requestConfirmations = 3;
    uint32 private constant numWords = 1;

    uint256 internal immutable fee;

    mapping(uint256 => uint256) public roundBank;
    mapping(uint256 => uint256) public roundPlayersCount;
    mapping(uint256 => mapping(address => bool)) public isRoundPlayer;
    mapping(address => uint256[]) public playersRounds;
    mapping(uint256 => LuckyRoundBet[]) public roundBets;
    mapping(address => uint256) public claimableBonus;
    mapping(uint256 => uint256) public roundRequests;
    mapping(uint256 => uint256) public requestRounds;
    mapping(uint256 => uint256) public roundBonusShares;
    mapping(address => address) public betsPlayer;
    mapping(uint256 => mapping(address => uint256)) public roundPlayerVolume;
    mapping(uint256 => mapping(address => uint256)) public roundPlayerBetsCount;

    // 0 - pending
    // 1 - waiting result
    // 2 - finished
    mapping(uint256 => uint8) public roundStatus;
    mapping(uint256 => uint256) public roundWinners;
    mapping(uint256 => bool) public roundDistribution;
    mapping(uint256 => uint256) public distributedBetCount;
    mapping(uint256 => mapping(address => bool)) public roundBetDistributed;

    mapping(uint256 => uint256) public lastOffset;

    event RequestedCalculation(
        uint256 indexed round,
        uint256 indexed requestId
    );
    event WinnerCalculated(
        uint256 indexed round,
        uint256 indexed winnerOffset,
        address indexed bet
    );
    event BonusClaimed(address indexed player, uint256 indexed amount);
    event BetCreated(
        address indexed player,
        uint256 indexed round,
        uint256 amount
    );

    event RoundStart(uint256 indexed round, uint256 indexed timestamp);

    constructor(
        address _core,
        address _staking,
        address _admin,
        uint256 _subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_vrfCoordinator != address(0), "RO01");
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        created = block.timestamp;
        core = _core;
        token = CoreInterface(_core).token();
        require(CoreInterface(_core).isStaking(_staking), "L01");
        staking = _staking;
        fee = CoreInterface(core).fee();
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function getBetsCount(uint round) public view returns (uint256) {
        return roundBets[round].length;
    }

    function getPlayersRoundsCount(
        address player
    ) public view returns (uint256) {
        return playersRounds[player].length;
    }

    function placeBet(
        address _player,
        uint256 _totalAmount,
        bytes calldata _data
    ) external override returns (address) {
        require(msg.sender == core, "L13");
        // parse data
        (address player, uint256 amount, uint256 round) = abi.decode(
            _data,
            (address, uint256, uint256)
        );
        // revert if player is not the same
        require(player == _player, "L02");
        // revert if amount is not whole
        require(amount * 10 ** 18 == _totalAmount, "L03");
        // revert if amount is too low
        require(_totalAmount >= MIN_BET_AMOUNT, "L05");
        // revert if round is not the same
        require(round == getCurrentRound(), "L04");
        // revert if round is full
        require((getBetsCount(round) + 1) <= BETS_LIMIT, "L07");
        // revert if round is already started
        require(roundStatus[round] == 0, "L10");
        // calculate startOffset
        uint256 prevOffset = lastOffset[round] + 1;
        // update lastOffset
        lastOffset[round] += amount;
        // create bet
        LuckyRoundBet bet = new LuckyRoundBet(
            player,
            address(this),
            _totalAmount,
            round,
            prevOffset,
            lastOffset[round]
        );
        // push bet to roundBets
        roundBets[round].push(bet);
        // mark player as active in this round and increment roundPlayers
        if (!isRoundPlayer[round][player]) {
            isRoundPlayer[round][player] = true;
            roundPlayersCount[round]++;
            playersRounds[player].push(round);
        }
        // update player's volume on this round
        roundPlayerVolume[round][player] += _totalAmount;
        roundPlayerBetsCount[round][player]++;
        // update round's bank
        roundBank[round] += _totalAmount;
        roundBonusShares[round] += roundBank[round];
        betsPlayer[address(bet)] = player;
        if (getBetsCount(round) == BETS_LIMIT) {
            requestCalculationInternal(round);
        }
        emit BetCreated(player, round, _totalAmount);
        if (getBetsCount(round) == 1) {
            emit RoundStart(round, block.timestamp);
        }
        return address(bet);
    }

    function requestCalculation(uint256 round) public {
        require(round < getCurrentRound(), "L09");
        require(roundStatus[round] == 0, "L10");
        require(getBetsCount(round) > 0, "L11");
        requestCalculationInternal(round);
    }

    function requestCalculationInternal(uint256 round) internal nonReentrant {
        uint256 requestId = VRFCoordinatorV2_5(vrfCoordinator)
            .requestRandomWords(
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: keyHash,
                    subId: subscriptionId,
                    requestConfirmations: requestConfirmations,
                    callbackGasLimit: callbackGasLimit,
                    numWords: numWords,
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            );
        roundRequests[round] = requestId;
        requestRounds[requestId] = round;
        roundStatus[round] = 1;
        emit RequestedCalculation(round, requestId);
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 round = requestRounds[requestId];
        uint256 winnerOffset = (randomWords[0] % lastOffset[round]) + 1; // exclude 0
        roundWinners[round] = winnerOffset;
        executeResult(round);
        roundStatus[round] = 2;
    }

    function executeResult(uint256 round) internal nonReentrant {
        uint256 winnerOffset = roundWinners[round];
        LuckyRoundBet[] storage bets = roundBets[round];
        // find using binary search
        uint256 low = 0;
        uint256 high = bets.length - 1;

        while (low <= high) {
            uint256 mid = (low + high) / 2;
            LuckyRoundBet bet = bets[mid];
            uint256 start = bet.getStartOffset();
            uint256 end = bet.getEndOffset();

            if (start <= winnerOffset && end >= winnerOffset) {
                uint256 bank = roundBank[round];
                // calculate bonus fee
                uint256 bonus = (bank * BONUS) / 100_00;
                // calculate reward
                uint reward = bank - ((bank * fee) / 100_00) - bonus;
                // transfer reward to player
                require(IERC20(token).transfer(bet.getPlayer(), reward), "L14");
                emit WinnerCalculated(round, winnerOffset, address(bet));
                break;
            } else if (end < winnerOffset) {
                low = mid + 1;
            } else {
                high = mid - 1;
            }
        }
    }

    function distribute(uint256 round, uint256 offset, uint256 limit) external {
        require(round < getCurrentRound(), "L09");
        require(roundStatus[round] == 2, "L12");
        require(roundDistribution[round] == false, "L08");
        LuckyRoundBet[] storage bets = roundBets[round];
        uint256 winnerOffset = roundWinners[round];
        uint256 bonusShares = roundBonusShares[round];
        uint256 bonus = (roundBank[round] * BONUS) / 100_00;
        for (uint256 i = offset; i < offset + limit; i++) {
            if (i >= bets.length) break;
            LuckyRoundBet bet = bets[i];
            if (roundBetDistributed[round][address(bet)]) continue;
            address player = betsPlayer[address(bet)];
            uint256 playerShare = bet.getAmount() * (bets.length - i);
            uint256 playerBonus = (bonus * playerShare) / bonusShares;
            claimableBonus[player] += playerBonus;
            roundBetDistributed[round][address(bet)] = true;
            bet.setResult(winnerOffset);
            distributedBetCount[round]++;
        }
        if (distributedBetCount[round] == roundBets[round].length) {
            roundDistribution[round] = true;
        }
    }

    function claimBonus(address player) external {
        require(
            _msgSender() == player || hasRole(SERVICE, _msgSender()),
            "L02"
        );
        uint bonus = claimableBonus[player];
        claimableBonus[player] = 0;
        require(IERC20(token).transfer(player, bonus), "L14");
        emit BonusClaimed(player, bonus);
    }

    function addService(address _service) external onlyRole(TIMELOCK) {
        _grantRole(SERVICE, _service);
    }

    function getCurrentRound() public view returns (uint256) {
        return (block.timestamp + 6 hours) / ROUND_DURATION;
    }

    function getAddress() public view override returns (address) {
        return address(this);
    }

    function getVersion() public view override returns (uint256) {
        return created;
    }

    function getFeeType() public pure override returns (uint256) {
        return 0;
    }

    function getStaking() public view override returns (address) {
        return staking;
    }

    function setMinBetAmount(uint256 _amount) external onlyRole(TIMELOCK) {
        require(_amount > 1 ether && _amount < 1_000_000 ether, "L06");
        MIN_BET_AMOUNT = _amount;
    }
}
