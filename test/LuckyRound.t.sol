// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/console.sol";
import "forge-std/Test.sol";
import "../src/shared/Token.sol";
import "../src/shared/Core.sol";
import "../src/shared/staking/StakingInterface.sol";
import "../src/LuckyRound.sol";

contract LuckyRoundTest is Test {
    Token public token;
    address public staking = address(999000999000);
    Core public core;
    LuckyRound public luckyRound;
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
        luckyRound = new LuckyRound(
            address(core),
            address(staking),
            address(this),
            555,
            0x7a1BaC17Ccc5b313516C5E16fb24f7659aA5ebed,
            0x4b09e658ed251bcafeebbc69400383d49f344ace09b9576fe248bb02c003fe9f
        );
        core.addGame(address(luckyRound));
        betsMemory.addAggregator(address(core));
        luckyRound.grantRole(luckyRound.TIMELOCK(), address(this));
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
        uint256 round
    ) private returns (address) {
        vm.startPrank(player);
        token.approve(address(core), amount * 1 ether);
        address bet = partner.placeBet(
            address(luckyRound),
            amount * 1 ether,
            abi.encode(player, amount, round)
        );
        vm.stopPrank();
        return bet;
    }

    function testConstructor() public view {
        assertEq(luckyRound.getAddress(), address(luckyRound));
        assertEq(luckyRound.getStaking(), address(staking));
    }

    function testBrokenBet() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = (uint256(1711450800) + 6 hours) / 1 days;
        assertEq(luckyRound.getCurrentRound(), round);
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        vm.expectRevert(bytes("L03"));
        partner.placeBet(
            address(luckyRound),
            100 ether,
            abi.encode(alice, 100 ether, round)
        );
        vm.expectRevert(bytes("L02"));
        partner.placeBet(
            address(luckyRound),
            100 ether,
            abi.encode(bob, 100, round)
        );
        vm.expectRevert(bytes("L05"));
        partner.placeBet(
            address(luckyRound),
            100 ether,
            abi.encode(alice, 100, round)
        );
        vm.expectRevert(bytes("L04"));
        partner.placeBet(
            address(luckyRound),
            1000 ether,
            abi.encode(alice, 1000, round - 1)
        );
        vm.stopPrank();
        assertEq(token.balanceOf(address(luckyRound)), 0);
    }

    function testSingleBet() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        address bet = placeBet(alice, 1000, round);
        assertEq(luckyRound.roundBank(round), 1000 ether);
        assertEq(luckyRound.getBetsCount(round), 1);
        assertEq(luckyRound.getPlayersRoundsCount(alice), 1);
        assertEq(luckyRound.getPlayersRoundsCount(bob), 0);
        assertEq(luckyRound.roundPlayersCount(round), 1);

        assertEq(LuckyRoundBet(bet).getPlayer(), alice);
        assertEq(LuckyRoundBet(bet).getGame(), address(luckyRound));
        assertEq(LuckyRoundBet(bet).getAmount(), 1000 ether);
        assertEq(LuckyRoundBet(bet).getStatus(), 1);
        assertEq(LuckyRoundBet(bet).getCreated(), 1711450800);
        assertEq(LuckyRoundBet(bet).getResult(), 0);
        assertEq(LuckyRoundBet(bet).getRound(), round);
        assertEq(LuckyRoundBet(bet).getStartOffset(), 1);
        assertEq(LuckyRoundBet(bet).getEndOffset(), 1000);
    }

    function testMultipleBets() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        for (uint160 i = 1; i <= 100; i++) {
            LuckyRoundBet bet = LuckyRoundBet(
                placeBet(address(i), 1000, round)
            );
            assertEq(bet.getPlayer(), address(i));
            assertEq(bet.getGame(), address(luckyRound));
            assertEq(bet.getAmount(), 1000 ether);
            assertEq(bet.getStatus(), 1);
            assertEq(bet.getStartOffset(), (i - 1) * 1000 + 1);
            assertEq(bet.getEndOffset(), (i - 1) * 1000 + 1000);
        }
        assertEq(luckyRound.roundBank(round), 1000 ether * 100);
        assertEq(luckyRound.getBetsCount(round), 100);
    }

    function testFullRound() public {
        getRequest(5);
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        for (uint k = 0; k < 10; k++) {
            for (uint160 i = 1; i <= 100; i++) {
                token.transfer(address(i), 1000 ether);
                placeBet(address(i), 1000, round);
            }
        }
        assertEq(luckyRound.getBetsCount(round), 1000);
        token.transfer(alice, 1000 ether);
        vm.startPrank(alice);
        token.approve(address(core), 1000 ether);
        vm.expectRevert(bytes("L07"));
        partner.placeBet(
            address(luckyRound),
            1000 ether,
            abi.encode(alice, 1000, round)
        );
        assertEq(luckyRound.getBetsCount(round), 1000);
        vm.stopPrank();

        assertEq(luckyRound.roundBank(round), 1000 ether * 1000);
        assertEq(luckyRound.getBetsCount(round), 1000);
        assertEq(luckyRound.roundStatus(round), 1);
    }

    function testCalculateRound_onePlayer(uint8 count) public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        placeBet(alice, 1000, round);

        // warp to 26/03/2024 11:10:00
        vm.warp(block.timestamp + 1 days);
        assertEq(luckyRound.getCurrentRound(), round + 1);

        // request calculation
        getRequest(5);
        luckyRound.requestCalculation(round);
        assertEq(luckyRound.roundStatus(round), 1);
        vm.startPrank(luckyRound.vrfCoordinator());
        uint256[] memory result = new uint256[](1);
        result[0] = uint256(count);
        luckyRound.rawFulfillRandomWords(5, result);
        assertEq(luckyRound.roundStatus(round), 2);

        assertEq(token.balanceOf(alice), 924 ether);
        // assertEq(luckyRound.claimableBonus(alice), 40 ether);
    }

    function testCalculateRound_multipleBets_samePlayer() public {
        getRequest(5);
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        for (uint160 i = 0; i < 1000; i++) {
            token.transfer(alice, 1000 ether);
            placeBet(alice, 1000, round);
        }
        assertEq(luckyRound.getBetsCount(round), 1000);
        assertEq(luckyRound.roundBank(round), 1000 ether * 1000);
        // warp to 26/03/2024 11:10:00
        vm.warp(block.timestamp + 1 days);
        assertEq(luckyRound.getCurrentRound(), round + 1);

        assertEq(luckyRound.roundStatus(round), 1);
        vm.startPrank(luckyRound.vrfCoordinator());
        uint256[] memory result = new uint256[](1);
        result[
            0
        ] = 93638604681615816415688588086267276884719664454054193024715406609462129623576;

        luckyRound.rawFulfillRandomWords(5, result);
        vm.stopPrank();
        luckyRound.distribute(round, 0, 300);
        luckyRound.distribute(round, 300, 300);
        luckyRound.distribute(round, 600, 400);
        assertEq(luckyRound.roundStatus(round), 2);
        assertEq(token.balanceOf(alice), 924000 ether + 1000 ether);
        assertApproxEqAbs(luckyRound.claimableBonus(alice), 40000 ether, 500);
        vm.startPrank(alice);
        luckyRound.claimBonus(alice);
        vm.stopPrank();
        assertApproxEqAbs(
            token.balanceOf(alice),
            924000 ether + 1000 ether + 40000 ether,
            500
        );
        assertApproxEqAbs(token.balanceOf(address(luckyRound)), 0 ether, 500);
    }
    function testCalculateRound_twoBets() public {
        getRequest(5);

        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        placeBet(alice, 1000, round);
        placeBet(bob, 1000, round);
        assertEq(luckyRound.getBetsCount(round), 2);
        // warp to 26/03/2024 11:10:00
        vm.warp(block.timestamp + 1 days);
        assertEq(luckyRound.getCurrentRound(), round + 1);

        // request calculation
        luckyRound.requestCalculation(round);
        assertEq(luckyRound.roundStatus(round), 1);
        vm.startPrank(luckyRound.vrfCoordinator());
        uint256[] memory result = new uint256[](1);
        result[0] = 1;
        luckyRound.rawFulfillRandomWords(5, result);
        luckyRound.distribute(round, 0, 300);
        assertEq(luckyRound.roundStatus(round), 2);
        assertEq(token.balanceOf(alice), 1848 ether);
        assertEq(token.balanceOf(bob), 0 ether);
        // assertApproxEqAbs(luckyRound.claimableBonus(alice), 53 ether, 1 ether);
        // assertApproxEqAbs(luckyRound.claimableBonus(bob), 27 ether, 1 ether);
    }

    function testDistribute_halves() public {
        getRequest(5);

        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        for (uint160 i = 0; i < 100; i++) {
            token.transfer(alice, 1000 ether);
            placeBet(alice, 1000, round);
        }
        for (uint160 i = 0; i < 100; i++) {
            token.transfer(bob, 1000 ether);
            placeBet(bob, 1000, round);
        }

        assertEq(luckyRound.getBetsCount(round), 200);
        // warp to 26/03/2024 11:10:00
        vm.warp(block.timestamp + 1 days);
        assertEq(luckyRound.getCurrentRound(), round + 1);

        // request calculation
        luckyRound.requestCalculation(round);
        assertEq(luckyRound.roundStatus(round), 1);
        vm.startPrank(luckyRound.vrfCoordinator());
        uint256[] memory result = new uint256[](1);
        result[0] = 1;
        luckyRound.rawFulfillRandomWords(5, result);
        assertEq(token.balanceOf(alice), 1000 ether + 184800 ether);

        // distribute
        luckyRound.distribute(round, 0, 100);
        // assertApproxEqAbs(
        //     luckyRound.claimableBonus(alice),
        //     5990 ether,
        //     1 ether
        // );
        // luckyRound.distribute(round, 100, 200);
        // assertApproxEqAbs(luckyRound.claimableBonus(bob), 2009 ether, 1 ether);
    }

    function testEdgeCases() public {
        getRequest(5);
        // distribute future round
        vm.expectRevert(bytes("L09"));
        luckyRound.distribute(23048723, 0, 100);

        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        placeBet(alice, 1000, round);

        // distribute before round end
        vm.expectRevert(bytes("L09"));
        luckyRound.distribute(round, 0, 100);
        // warp to 26/03/2024 11:10:00
        vm.warp(block.timestamp + 1 days);
        // distribute before calculation
        vm.expectRevert(bytes("L12"));
        luckyRound.distribute(round, 0, 100);

        // request calculation
        luckyRound.requestCalculation(round);

        // distribute after calculation before result
        vm.expectRevert(bytes("L12"));
        luckyRound.distribute(round, 0, 100);
    }

    function testOnlyCore_placeBet() public {
        // warp to 26/03/2024 11:00:00
        vm.warp(1711450800);
        uint256 round = luckyRound.getCurrentRound();
        bytes memory data = abi.encode(alice, 500, round);
        vm.expectRevert(bytes("L13"));
        luckyRound.placeBet(alice, 500 ether, data);
    }

    function testCurrentRound() public {
        // Tue Aug 06 2024 14:00:00 GMT+0000
        vm.warp(1722952800);
        assertEq(19941, luckyRound.getCurrentRound());

        // Tue Aug 06 2024 17:59:59 GMT+0000
        vm.warp(1722967199);
        assertEq(19941, luckyRound.getCurrentRound());

        // Tue Aug 06 2024 18:00:00 GMT+0000
        vm.warp(1722967200);
        assertEq(19942, luckyRound.getCurrentRound());
    }
}
