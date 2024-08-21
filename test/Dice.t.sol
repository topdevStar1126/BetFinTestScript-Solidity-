// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "../src/shared/Token.sol";
import "../src/shared/Core.sol";
import "../src/shared/staking/StakingInterface.sol";
import "../src/shared/games/dice/Dice.sol";

contract DiceTest is Test {
    Token public token;
    address public staking = address(999000999000);
    Core public core;
    Dice public dice;
    Partner public partner;
    BetsMemory public betsMemory;
    Pass public pass;
    address public affiliate = address(128911982379182361);

    address public alice = address(1);
    address public bob = address(2);
    address public carol = address(3);
    address public dave = address(4);
    address public eve = address(5);

    function setUp() public {
        pass = new Pass(address(this));
        pass.grantRole(pass.TIMELOCK(), address(this));
        pass.setAffiliate(affiliate);
        vm.mockCall(
            affiliate,
            abi.encodeWithSelector(
                AffiliateInterface.checkInviteCondition.selector,
                address(1)
            ),
            abi.encode(true)
        );
        vm.mockCall(
            address(pass),
            abi.encodeWithSelector(AffiliateMember.getInviter.selector, alice),
            abi.encode(address(0))
        );
        pass.mint(alice, address(0), address(0));

        token = new Token(address(this));
        betsMemory = new BetsMemory(address(this));
        betsMemory.grantRole(betsMemory.TIMELOCK(), address(this));
        betsMemory.setPass(address(pass));
        core = new Core(
            address(token),
            address(betsMemory),
            address(pass),
            address(this)
        );
        core.grantRole(core.TIMELOCK(), address(this));
        vm.mockCall(
            address(staking),
            abi.encodeWithSelector(StakingInterface.getAddress.selector),
            abi.encode(address(staking))
        );
        core.addStaking(address(staking));
        dice = new Dice(
            address(core),
            address(staking),
            address(this),
            555,
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
        );
        core.addGame(address(dice));
        betsMemory.addAggregator(address(core));
        dice.grantRole(dice.TIMELOCK(), address(this));
        address tariff = core.addTariff(0, 1_00, 0);
        vm.startPrank(carol);
        partner = Partner(core.addPartner(tariff));
        vm.stopPrank();
        for (uint160 i = 1; i <= 100; i++) {
            if (i > 1) {
                pass.mint(address(i), alice, alice);
            }
            token.transfer(address(i), 1000 ether);
        }
    }

    function getRequest(uint256 requestId) internal {
        vm.mockCall(
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            abi.encodeWithSelector(
                VRFCoordinatorV2_5.requestRandomWords.selector,
                VRFV2PlusClient.RandomWordsRequest({
                    keyHash: bytes32(
                        0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
                    ),
                    subId: uint256(555),
                    requestConfirmations: uint16(3),
                    callbackGasLimit: uint32(2_500_000),
                    numWords: uint32(1),
                    extraArgs: VRFV2PlusClient._argsToBytes(
                        VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                    )
                })
            ),
            abi.encode(requestId)
        );
    }

    function placeBet(
        address player,
        uint256 amount,
        uint256 threshold,
        bool side
    ) private returns (address) {
        vm.startPrank(player);
        token.approve(address(core), amount * 1 ether);
        address bet = partner.placeBet(
            address(dice),
            amount * 1 ether,
            abi.encode(player, amount, threshold, side)
        );
        vm.stopPrank();
        return bet;
    }

    function testConstructor() public view {
        assertEq(dice.getAddress(), address(dice));
        assertEq(dice.getStaking(), address(staking));
    }

    function testBrokenBet() public {
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);

        vm.expectRevert(bytes("D02"));
        partner.placeBet(
            address(dice), 100 ether,
            abi.encode(bob, 100, 5000, 1)
        );
        
        vm.expectRevert(bytes("D03"));
        partner.placeBet(
            address(dice),
            100 ether,
            abi.encode(alice, 100 ether, 5000, 1)
        );

        vm.expectRevert(bytes("D04"));
        partner.placeBet(
            address(dice), 100 ether,
            abi.encode(alice, 100 , 0, 1)
        );

        vm.stopPrank();
        assertEq(token.balanceOf(address(dice)), 0);
    }

    function testSingleBet() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        address bet = placeBet(alice, 1000, 5000, true);

        assertEq(DiceBet(bet).getPlayer(), alice);
        assertEq(DiceBet(bet).getGame(), address(dice));
        assertEq(DiceBet(bet).getAmount(), 1000 ether);
        assertEq(DiceBet(bet).getStatus(), 1);
        assertEq(DiceBet(bet).getCreated(), 1711450800);
        assertEq(DiceBet(bet).getResult(), 0);
    }

    function testFullRound() public {
        getRequest(5);
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        token.transfer(alice, 5000 ether);
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        partner.placeBet(
            address(dice),
            1000 ether,
            abi.encode(alice, 1000, 5000, 1)
        );
        vm.stopPrank();
    }

    function testOnlyCore_placeBet() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        bytes memory data = abi.encode(alice, 500, 5000, true);
        vm.expectRevert(bytes("D05"));
        dice.placeBet(alice, 500 ether, data);
    }
}
