// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "openzeppelin/access/Ownable.sol";
import "./shared/BetInterface.sol";

contract LuckyRoundBet is Ownable, BetInterface {
    address private immutable player;
    address private immutable game;
    uint256 private immutable amount;
    uint256 private immutable created;

    // 1 - registered
    // 2 - won
    // 3 - lost
    uint256 private status;
    uint256 private result;
    uint256 private immutable round;
    uint256 private immutable startOffset;
    uint256 private immutable endOffset;

    constructor(
        address _player,
        address _game,
        uint256 _amount,
        uint256 _round,
        uint256 _startOffset,
        uint256 _endOffset
    ) {
        created = block.timestamp;
        player = _player;
        game = _game;
        amount = _amount;
        round = _round;
        status = 1;
        startOffset = _startOffset;
        endOffset = _endOffset;
    }

    function getRound() public view returns (uint256) {
        return round;
    }

    function getPlayer() external view override returns (address) {
        return player;
    }

    function getGame() external view override returns (address) {
        return game;
    }

    function getAmount() external view override returns (uint256) {
        return amount;
    }

    function getStatus() external view override returns (uint256) {
        return status;
    }

    function getCreated() external view override returns (uint256) {
        return created;
    }

    function getResult() external view override returns (uint256) {
        return result;
    }

    function getBetInfo()
        external
        view
        override
        returns (address, address, uint256, uint256, uint256, uint256)
    {
        return (player, game, amount, result, status, created);
    }

    function setResult(uint256 _result) external onlyOwner {
        result = _result;
        if (_result >= startOffset && _result <= endOffset) {
            status = 2;
        } else {
            status = 3;
        }
    }

    function getStartOffset() external view returns (uint256) {
        return startOffset;
    }

    function getEndOffset() external view returns (uint256) {
        return endOffset;
    }
}
