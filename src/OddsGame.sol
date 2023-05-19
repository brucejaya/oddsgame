// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './IOddsGame.sol';

import 'chainlink/contracts/src/v0.8/vrf/VRFV2WrapperConsumerBase.sol';
import 'openzeppelin-contracts/contracts/access/Ownable.sol';
import 'openzeppelin-contracts/contracts/security/ReentrancyGuard.sol';
import 'openzeppelin-contracts/contracts/security/Pausable.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

contract OddsGame is IOddsGame, VRFV2WrapperConsumerBase, Ownable, ReentrancyGuard, Pausable {
    
    ////////////////
    // USING
    ////////////////

    using SafeERC20 for IERC20;

    ////////////////
    // CHAINLINK
    ////////////////
    
    /** 
     * @dev Chainlink VRF gas limit.
     *
     * Depends on the number of requested values that you want sent to the * fulfillRandomWords() function. Test
     * and adjust this limit based on the network that you select, the size of the request, and the processing 
     * of the callback request in the fulfillRandomWords() function.
     */
    uint32 _callbackGasLimit = 100000;

    /** 
     * @dev Chainlink VRF requested confirmations. The default is 3, but this can be set higher.
     */
    uint16 _requestConfirmations = 3;
    
    /** 
     * @dev Chainlink VRF amount of random numbers requested. Cannot exceed VRFV2Wrapper.getConfig().maxNumWords.
     */
    uint32 _numWords = 1;

    ////////////////
    // CONSTANTS
    ////////////////
    
    /**
     * @dev Modulo is the number of equiprobable outcomes in a game so: 2 for coin flip, 6 for dice roll, 
     * 6*6 = 36 for double dice or 37 for roulette.
     */
    uint256 internal constant MAX_MODULO = 100;

    /** 
     * @dev Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes. 
     *
     * For example in a dice roll (modulo = 6), 000001 mask means betting on 1. 000001 converted from binary to
     * decimal becomes 1. 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes
     * 40. The specific value is dictated by the fact that 256-bit intermediate multiplication result allows 
     * implementing population count efficiently for numbers that are up to 42 bits, and 40 is the highest multiple
     * of eight below 42.
     */
    uint256 internal constant MAX_MASK_MODULO = 40;

    /**
     * @dev This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
     */
    uint256 internal constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    /**
     * @dev These are constants taht make O(1) population count in placeBet possible.
     */
    uint256 internal constant POPCNT_MULT = 0x0000000000002000000000100000000008000000000400000000020000000001;
    uint256 internal constant POPCNT_MASK = 0x0001041041041041041041041041041041041041041041041041041041041041;
    uint256 internal constant POPCNT_MODULO = 0x3F;

    ////////////////
    // CONFIG
    ////////////////
    
    /**
     * @dev Chainlink fee per bet.
     */
    uint256 public _chainlinkFee = 0.1 * 10 ** 18;

    /**
     * @dev Each bet is deducted 1% in favor of the house.
     */
    uint256 public _houseEdgePercent = 1;
    
    /**
     * @dev In addition to house edge, wealth tax is added every time the bet amount exceeds a multiple of a threshold.
     *
     * For example, if _wealthTaxIncrementThreshold = 3000 ether,
     * A bet amount of 3000 ether will have a wealth tax of 1% in addition to house edge.
     * A bet amount of 6000 ether will have a wealth tax of 2% in addition to house edge.
     */
    uint256 public _wealthTaxIncrementThreshold = 3000 ether;
    uint256 public _wealthTaxIncrementPercent = 1;

    /**
     * @dev The minimum and maximum bets.
     */
    uint256 public _minBetAmount = 0.001 ether;
    uint256 public _maxBetAmount = 100 ether;

    /**
     * @dev Max bet profit. Used to cap bets against dynamic odds.
     */
    uint256 public _maxProfit = 3000 ether;

    ////////////////
    // CONSTRUCTOR
    ////////////////

    struct Bet {
        uint256 amount; // Wager amount in wei.
        uint8 modulo; // Modulo of a game used instead of mask for games with modulo > MAX_MASK_MODULO. // 
        uint8 rollUnder; // Number of winning outcomes, used to compute winning payment (* modulo/rollUnder), 
        uint40 mask; // Bit mask representing winning bet outcomes (see MAX_MASK_MODULO comment).
        uint256 placeBlockNumber; // Block number of placeBet tx.
        address payable gambler; // Address of a gambler, used to pay out winning bets.
        bool isSettled; // Status of bet settlement.
        uint256 outcome; // Outcome of bet.
        uint256 winAmount; // Win amount.
        uint256 randomNumber; // Random number used to settle bet.
    }

    /**
     * @dev List of bets.
     */
    Bet[] public _bets;

    /**
     * @dev Mapping from Chainlink VRF requestId to bet index.
     */
    mapping(uint256 => uint256) public _betsByRequestId;

    /**
     * @dev Mapping from user to bet index where isSettled is false.
     */
    mapping(address => uint256[]) _openBetsByUser;

    /**
     * @dev Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
     */
    uint256 public _betAmountLockIn;

    /**
     * @dev Sum of all historical deposits and withdrawals. Used for calculating profitability. 
     * Profit = Balance - _betAmountCumulativeDeposit + _betAmountCumulativeWithdrawal.
     */
    uint256 public _betAmountCumulativeDeposit;
    uint256 public _betAmountCumulativeWithdrawal;

    ////////////////
    // CONSTRUCTOR
    ////////////////

    constructor(address _linkAddress, address _wrapperAddress) VRFV2WrapperConsumerBase(_linkAddress, _wrapperAddress) {}
   
    //////////////////////////////////////////////
    // BET RESOLUTION
    //////////////////////////////////////////////

    /**
     * @dev Place a new bet.
     * @param betMask The numeric value of the bet. For coinflip, 1 for heads, 2 for tails, etc.
     * @param modulo The modulo for the game. 2 for coinflip. 6 for dice, etc.
     */
    function placeBet(
        uint256 betMask,
        uint256 modulo
    )
        external
        payable
        nonReentrant
    {
        // Validate input data
        uint256 amount = msg.value;

        if (LINK.balanceOf(address(this)) < _chainlinkFee)
            revert NotEnoughLinkToken();
        if (amount < _minBetAmount || _maxBetAmount < amount)
            revert BetOutOfRange(amount);

        if (modulo <= 1|| MAX_MODULO < modulo)
            revert ModuloOutOfRange(modulo);
        if (betMask == 0 || MAX_BET_MASK < betMask)
            revert BetMaskOutOfRange(betMask);
            
        uint256 rollUnder;
        uint256 mask;

        if (modulo <= MAX_MASK_MODULO) {
            // rollUnder is a number of 1 bits in this mask (population count).
            // Small modulo games can specify exact bet outcomes via bit mask.
            // This magic looking formula is an efficient way to compute population
            // count on EVM for numbers below 2**40. 
            rollUnder = ((betMask * POPCNT_MULT) & POPCNT_MASK) % POPCNT_MODULO;
            mask = betMask;
        }
        else {
            // Larger modulos games specify the right edge of half-open interval of winning bet outcomes.
            if (betMask == 0 || modulo < betMask)
                revert BetExceedsModulo();
            rollUnder = betMask;
        }
        
        uint256 possibleWinAmount = getDiceWinAmount(amount, modulo, rollUnder); // Winning amount.

        if (amount + _maxProfit < possibleWinAmount)
            revert WinExceedsMaxProfit();
        if (address(this).balance < _betAmountLockIn + possibleWinAmount)
            revert WinExceedsCurrentFunds();

        // Update locked funds.
        _betAmountLockIn += possibleWinAmount;

        // Store bet in bet list.
        _bets.push(Bet(
            {
                amount: amount,
                modulo: uint8(modulo),
                rollUnder: uint8(rollUnder),
                mask: uint40(mask),
                placeBlockNumber: block.number,
                gambler: payable(msg.sender),
                isSettled: false,
                outcome: 0,
                winAmount: 0,
                randomNumber: 0
            }
        ));

        // Request random number from Chainlink VRF. Store requestId for validation checks later.
        uint256 requestId = requestRandomness(_callbackGasLimit, _requestConfirmations, _numWords);

        // Add to mappings.
        _betsByRequestId[requestId] = _bets.length;
        _openBetsByUser[msg.sender].push(_bets.length);

        // Record bet in event logs.
        emit BetPlaced(_bets.length, msg.sender);
    }

    /**
     * @dev Refund a bet that has not been executed.
     * @param betId The id of the bet to be refunded.
     */
    function refundBet(
        uint256 betId
    )
        external
        nonReentrant
        payable
    {
        Bet storage bet = _bets[betId];

        // Sanity checks
        if (bet.amount == 0)
            revert BetNotExist();
        if (bet.isSettled)
            revert BetAlreadySettled();
        if (block.number < bet.placeBlockNumber + 43200)
            revert RefundPeriodNotElapsed();

        uint256 possibleWinAmount = getDiceWinAmount(bet.amount, bet.modulo, bet.rollUnder);
        _betAmountLockIn -= possibleWinAmount;
        bet.isSettled = true;
        bet.winAmount = bet.amount;
        bet.gambler.transfer(bet.amount);

        emit BetRefunded(betId, bet.gambler);
    }
 
    //////////////////////////////////////////////
    // INTERNAL FUNCTIONS
    //////////////////////////////////////////////

    /**
     * @dev Iterate through open bets by user are remove the betId.
     * @param user The address of the user who's open bets are being updated.
     * @param betId The id of the bet.
     */
    function _removeFromOpenBets(
        address user,
        uint256 betId
    )
        internal
    {
        for (uint8 i = 0; i < _openBetsByUser[user].length; i++)
            if (_openBetsByUser[user][i] == betId)
                delete _openBetsByUser[user][i];
    }

    /**
     * @dev The return function for Chainlink VRF wraps the _settleBet bet resolution function.
     * @param requestId Chainlink VRF request id used to identity the bet to resolve.
     * @param randomWords Array of random ints returned by chainlink.
     */
    function fulfillRandomWords(
        uint256 requestId,
        uint256[] memory randomWords
    )
        internal
        override
    {
        _settleBet(requestId, randomWords[0]);
    }

    /**
     * @dev Resolves a bet once random values have been recieved either for a win or loss.
     * @param requestId Chainlink VRF request id used to identity the bet to resolve.
     * @param randomNumber The random int returned by chainlink.
     */
    function _settleBet(
        uint256 requestId,
        uint256 randomNumber
    )
        internal
        nonReentrant
    {        
        uint256 betId = _betsByRequestId[requestId];
        Bet storage bet = _bets[betId];
        uint256 amount = bet.amount;
        
        if (bet.amount == 0)
            revert BetNotExist();
        if (bet.isSettled)
            revert BetAlreadySettled();

        // Fetch bet parameters into local variables (to save gas).
        uint256 modulo = bet.modulo;
        uint256 rollUnder = bet.rollUnder;
        address payable gambler = bet.gambler;

        // Do a roll by taking a modulo of random number.
        uint256 outcome = randomNumber % modulo;

        // Win amount if gambler wins this bet
        uint256 possibleWinAmount = getDiceWinAmount(amount, modulo, rollUnder);

        // Actual win amount by gambler
        uint256 winAmount = 0;

        // Determine dice outcome.
        if (modulo <= MAX_MASK_MODULO)
            // For small modulo games, check the outcome against a bit mask.
            if ((2 ** outcome) & bet.mask != 0)
                winAmount = possibleWinAmount;
        
        else
            // For larger modulos, check inclusion into half-open interval.
            if (outcome < rollUnder)
                winAmount = possibleWinAmount;
        
        // Record bet settlement in event log.
        emit BetSettled(betId, gambler, amount, uint8(modulo), uint8(rollUnder), bet.mask, outcome, winAmount);

        // Unlock possibleWinAmount from _betAmountLockIn, regardless of the outcome.
        _betAmountLockIn -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = winAmount;
        bet.randomNumber = randomNumber;
        bet.outcome = outcome;

        // Send win amount to gambler.
        if (0 < winAmount)
            gambler.transfer(winAmount);
    }
 
    //////////////////////////////////////////////
    // GETTERS
    //////////////////////////////////////////////

    /** 
     * @dev Returns an array of bet ids for the open bets of a user.
     * @param user The address of the user to query.
     */
    function getOpenBetsByUser(
        address user
    )   
        public
        view
        returns (uint256[] memory)
    {
        return  _openBetsByUser[user];
    }

    /** 
     * @dev Returns important fields from a bet for display.
     * @param betId The id of the bet field to query.
     */
    function getBet(
        uint256 betId
    )
        public
        view
        returns (
            uint256 amount_,
            uint8 modulo_,
            uint8 rollUnder_,
            uint256 placeBlockNumber_,
            bool isSettled_,
            uint256 outcome_,
            uint256 winAmount_
        )
    {
        amount_ = _bets[betId].amount;
        modulo_ = _bets[betId].modulo;
        rollUnder_ = _bets[betId].rollUnder;
        placeBlockNumber_ = _bets[betId].placeBlockNumber;
        isSettled_ = _bets[betId].isSettled;
        outcome_ = _bets[betId].outcome;
        winAmount_ = _bets[betId].winAmount;
    }

    /** 
     * @dev Returns the wealth tax for based of the bet amount.
     * @param amount The amount of funds bet.
     */
    function getWealthTax(
        uint256 amount
    )
        public
        view
        returns (uint256 wealthTax)
    {
        wealthTax = amount / _wealthTaxIncrementThreshold * _wealthTaxIncrementPercent;
    }
 
    /** 
     * @dev Returns the payout for a bet based on the odds.
     * @param amount The amount placed on the bet. See struct `Bet`.
     * @param modulo The modulo the the bet. See struct `Bet`.
     * @param rollUnder The roll under of the bet. See struct `Bet`.
     */
    function getDiceWinAmount(
        uint256 amount,
        uint256 modulo,
        uint256 rollUnder
    )
        public
        view
        returns (uint256 winAmount)
    {
        if (rollUnder == 0 || modulo < rollUnder)
            revert ProbablityOutOfRange();

        uint256 houseEdge = amount * (_houseEdgePercent + getWealthTax(amount)) / 100;
        winAmount = (amount - houseEdge) * modulo / rollUnder;
    }

    /** 
     * @dev Returns current eth balance of this contract.
     */
    function getBalanceETH()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }

    /** 
     * @dev Returns current LINK token balance of this contract.
     */
    function getBalanceLINK()
        external
        view
        returns (uint256)
    {
        return LINK.balanceOf(address(this));
    }

    //////////////////////////////////////////////
    // SETTERS
    //////////////////////////////////////////////

    /** 
     * @dev Sets the percent of profits for the house on winning bets.
     * @param houseEdgePercent The percentage to be taken on winning bets.
     */
    function setHouseEdge(
        uint256 houseEdgePercent
    )
        external
        onlyOwner
    {
        _houseEdgePercent = houseEdgePercent;
    }

    /** 
     * @dev Sets the minimum bet amount.
     * @param minBetAmount The minimum bet in wei.
     */
    function setMinBetAmount(
        uint256 minBetAmount
    )
        external
        onlyOwner
    {
        _minBetAmount = minBetAmount;
    }

    /** 
     * @dev Sets the maximum bet amount.
     * @param maxBetAmount The maximum bet in wei.
     */
    function setMaxBetAmount(
        uint256 maxBetAmount
    )
        external
        onlyOwner
    {
        if (5000000 ether < maxBetAmount)
            revert InsaneMaxBet();
        _maxBetAmount = maxBetAmount;
    }

    /** 
     * @dev Sets the maximum profit that any bet can return.
     * @param maxProfit The maximum bet value in wei.
     */
    function setMaxProfit(
        uint256 maxProfit
    )
        external
        onlyOwner
    {
        if (5000000 ether < maxProfit)
            revert InsaneMaxProfit();
        _maxProfit = maxProfit;
    }

    /** 
     * @dev Sets the threshold for each time wealth tax should be increased.
     * @param wealthTaxIncrementThreshold The multiple for the threshold, For example 2000, 4000, 6000. 
     */
    function setWealthTaxIncrementThreshold(
        uint256 wealthTaxIncrementThreshold
    )
        external
        onlyOwner
    {
        _wealthTaxIncrementThreshold = wealthTaxIncrementThreshold;
    }
    
    /** 
     * @dev Sets the amount by which wealth tax should be increased every time it passes a threshold.
     * @param wealthTaxIncrementPercent The percentage by which it should increase each threhsold, for example 2%, 4%, 6%, etc.
     */
    function setWealthTaxIncrementPercent(
        uint256 wealthTaxIncrementPercent
    )
        external
        onlyOwner
    {
        _wealthTaxIncrementPercent = wealthTaxIncrementPercent;
    }

    //////////////////////////////////////////////
    // OWNER FUNCTIONS
    //////////////////////////////////////////////

    /** 
     * @dev Withdraw eth from the contract.
     * @param beneficiary Account to pay.
     * @param withdrawAmount Amount to pay to beneficiary.
     */
    function withdrawFunds(
        address payable beneficiary,
        uint256 withdrawAmount
    )
        external
        onlyOwner
    {
        // Sanity checks
        if (address(this).balance < withdrawAmount)
            revert WithdrawExceedsBalance();
        if (address(this).balance - _betAmountLockIn < withdrawAmount)
            revert WithdrawExceedsFreeBalance();
        
        // Send funds
        beneficiary.transfer(withdrawAmount);

        // Update amount withdrawn
        _betAmountCumulativeWithdrawal += withdrawAmount;
    }

    /** 
     * @dev Withdraw tokens from the contract.
     */
    function withdrawTokens(
        address tokenAddress
    )
        external
        onlyOwner
    {
        IERC20(tokenAddress).safeTransfer(owner(), IERC20(tokenAddress).balanceOf(address(this)));
    }

    /** 
     * @dev Withdraw all tokens and funds from the contract.
     */
    function withdrawAll()
        external
        onlyOwner
    {
        uint256 withdrawAmount = address(this).balance - _betAmountLockIn;
        _betAmountCumulativeWithdrawal += withdrawAmount;
        payable(msg.sender).transfer(withdrawAmount);
        LINK.transfer(owner(), LINK.balanceOf(address(this)));
    }
    
    fallback()
        external
        payable
    {
        _betAmountCumulativeDeposit += msg.value;
    }

    receive()
        external
        payable
    {
        _betAmountCumulativeDeposit += msg.value;
    }
}