// SPDX-License-Identifier: MIT
pragma solidity 0.8.19;

import "chainlink/vrf/dev/VRFCoordinatorV2_5.sol";
import "chainlink/vrf/dev/VRFConsumerBaseV2Plus.sol";
import "openzeppelin/access/AccessControl.sol";
import "openzeppelin/security/ReentrancyGuard.sol";
import "openzeppelin/token/ERC20/IERC20.sol";
import "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "../GameInterface.sol";
import "../../CoreInterface.sol";
import "../../staking/StakingInterface.sol";
import "./DiceBet.sol";

/**
 * Errors used in this contract
 *
 * D01 - invalid staking contract
 * D02 - player address mismatch
 * D03 - amount invalid
 * D04 - threshold invalid
 * D05 - only core can place bets
 * D06 - invalid coordinator
 * D07 - staking pool balance insufficient
 */

import "forge-std/console.sol";

contract Dice is
    VRFConsumerBaseV2Plus,
    AccessControl,
    GameInterface,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    bytes32 public constant TIMELOCK = keccak256("TIMELOCK");

    uint256 public constant REQUIRED_FUNDS_COEFFICIENT = 20;
    uint256 private immutable created;
    uint256 private immutable subscriptionId;
    address public immutable vrfCoordinator;
    bytes32 public immutable keyHash;
    uint32 private constant callbackGasLimit = 2_500_000;
    uint16 public constant requestConfirmations = 3;
    uint32 private constant numWords = 1;

    StakingInterface public staking;
    CoreInterface public core;

    mapping(address => uint256[]) public playerRequests;
    mapping(uint256 => DiceBet) public requestBets;

    mapping(uint256 => uint256) public reservedFunds;

    event Rolled(
        address indexed bet,
        uint256 indexed requestId,
        address roller
    );
    event Landed(
        address indexed bet,
        uint256 indexed requestId,
        address roller,
        uint256 indexed result
    );

    constructor(
        address _core,
        address _staking,
        address _admin,
        uint256 _subscriptionId,
        address _vrfCoordinator,
        bytes32 _keyHash
    ) VRFConsumerBaseV2Plus(_vrfCoordinator) {
        require(_vrfCoordinator != address(0), "D06");
        vrfCoordinator = _vrfCoordinator;
        keyHash = _keyHash;
        subscriptionId = _subscriptionId;
        core = CoreInterface(_core);
        require(core.isStaking(_staking), "D01");
        staking = StakingInterface(_staking);
        created = block.timestamp;
        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
    }

    function getPossibleWin(
        uint256 _threshold,
        bool _side,
        uint256 _amount
    ) public pure returns (uint256) {
        uint256 multiplier;
        uint256 decimal = 10000;
        if(_side) {multiplier = 10000*decimal/_threshold;}
        else {multiplier = 10000*decimal/(9999-_threshold);}
        return multiplier*_amount/decimal; //consider that _amount is with decimal 
    }

    function roll(
        address player,
        uint256 amount,
        uint256 threshold,
        bool side
    ) internal nonReentrant returns (address) {
        // require(amount > 5000*(10^18), "D03");
        // validate threshold
        require(threshold<10000 && threshold>0, "D04");
        // calculate max possible win
        uint256 possibleWin = getPossibleWin(threshold, side, amount);
        // console.log(possibleWin);
        // console.log(IERC20(core.token()).balanceOf(address(staking)));
        // // check if there is enough tokens to cover bet
        // require(
        //     possibleWin * REQUIRED_FUNDS_COEFFICIENT <=
        //         IERC20(core.token()).balanceOf(address(staking)),
        //     "D07"
        // );
        // request random number
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

        // create and register bet
        DiceBet bet = new DiceBet(player, amount, 1, address(this));
        // bet.setRequestId(requestId);
        bet.setBets(threshold, side);
        requestBets[requestId] = bet;
        console.log(staking.getToken());
        console.log(address(staking));
        console.log(amount);
        IERC20(staking.getToken()).transfer(address(staking), amount);
        console.log(3);
        playerRequests[player].push(requestId);
        emit Rolled(address(bet), requestId, player);
        // transfer required amount to dice balance
        staking.reserveFunds(possibleWin);
        // reserve funds
        reservedFunds[requestId] = possibleWin;
        return address(bet);
    }

    function placeBet(
        address _player,
        uint256 _amount,
        bytes calldata _data
    ) external override returns (address betAddress) {
        require(address(core) == _msgSender(), "D05");
        (address player, uint256 amount, uint256 _threshold, bool _side) = abi.decode(
            _data,
            (address, uint256, uint256, bool)
        );
        //revert if player is not the same
        require(player==_player, "D02");
        //revert if amount is not whole
        require(amount * 10 ** 18 == _amount, "D03");

        return address(roll(_player, _amount, _threshold, _side));
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 random = randomWords[0];
        uint256 value = (random % 10000);
        DiceBet bet = requestBets[requestId];
        address player = bet.getPlayer();
        (uint256 threshold, bool side) = bet.getBets();
        bet.setWinNumber(value);
        bet.setStatus(2);
        uint256 amount = 0;
        if((value>threshold)==side) {
            amount = getPossibleWin(threshold, side, bet.getAmount());
        }
        bet.setResult(amount);
        if (amount > 0) {
            // send win amount ot player
            IERC20(core.token()).transfer(player, amount);
        }
        // send leftovers back to staking contract
        IERC20(core.token()).transfer(
            address(staking),
            reservedFunds[requestId] - amount
        );
        // clear reserved funds for current request
        reservedFunds[requestId] = 0;
        emit Landed(address(bet), requestId, player, value);
    }

    function getPlayerRequestsCount(
        address player
    ) public view returns (uint256) {
        return playerRequests[player].length;
    }

    function getRequestBet(uint256 requestId) public view returns (address) {
        return address(requestBets[requestId]);
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
        return address(staking);
    }
}