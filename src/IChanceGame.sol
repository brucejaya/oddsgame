// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

interface IChanceGame {

    ////////////////
    // EVENTS
    ////////////////

    /**
     * @dev A new bet has been placed
     */
    event BetPlaced(uint indexed betId, address indexed gambler);

    /**
     * @dev A placed bet has been settled
     */
	event BetSettled(uint indexed betId, address indexed gambler, uint amount, uint8 indexed modulo, uint8 rollUnder, uint40 mask, uint outcome, uint winAmount);
	
    /**
     * @dev A placed bet that could not be fulfilled has been refunded
     */
    event BetRefunded(uint indexed betId, address indexed gambler);
	
    ////////////////
    // ERRORS
    ////////////////

    /**
     * @dev Not enough LINK in contract
     */
    error NotEnoughLinkToken();

    /**
     * @dev Win probability out of range
     */
    error ProbablityOutOfRange();

    /**
     * @dev Modulo is out of range. Either over or under
     */
    error ModuloOutOfRange(uint256 amount);

    /**
     * @dev Bet amount is out of range. Either over or under
     */
    error BetOutOfRange(uint256 amount);

    /**
     * @dev Bet mask is out of range. Either over or under
     */
    error BetMaskOutOfRange(uint256 amount);

    /**
     * @dev High modulo range, betMask larger than modulo
     */
    error BetExceedsModulo();

    /**
     * @dev Potentional win amount exceeds maximum profit
     */
    error WinExceedsMaxProfit();

    /**
     * @dev Unable to accept bet due to insufficient funds
     */
    error WinExceedsCurrentFunds();

    /**
     * @dev Bet does not exist
     */
    error BetNotExist();

    /**
     * @dev Bet is already settled
     */
    error BetAlreadySettled();

    /**
     * @dev Wait after placing bet before requesting refund
     */
    error RefundPeriodNotElapsed();

    /**
     * @dev Must be a sane number for maxBetAmount
     */
    error InsaneMaxBet();

    /**
     * @dev Must be a sane number for _maxProfit
     */
    error InsaneMaxProfit();

    /**
     * @dev Withdrawal amount larger than balance
     */
    error WithdrawExceedsBalance();

    /**
     * @dev Withdrawal amount larger than balance minus lockedInBets
     */
    error WithdrawExceedsFreeBalance();

}