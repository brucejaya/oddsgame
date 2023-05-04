// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

import './IChanceGame.sol';

import 'chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol';
import 'openzeppelin-contracts/contracts/access/Ownable.sol';
import 'openzeppelin-contracts/contracts/security/ReentrancyGuard.sol';
import 'openzeppelin-contracts/contracts/security/Pausable.sol';
import 'openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol';

contract ChanceGame is IChanceGame, VRFConsumerBaseV2, Ownable, ReentrancyGuard, Pausable {
    
    ////////////////
    // USING
    ////////////////

    using SafeERC20 for IERC20;

    ////////////////
    // CONSTANTS
    ////////////////
    
    /** 
     * @dev Chainlink VRF
     */
    address public constant LINK_TOKEN = 0x01BE23585060835E02B77ef475b0Cc51aA1e0709;// polygon 0xb0897686c545045aFc77CF20eC7A532E3120E0F1;
    address public constant VRF_COORDINATOR = 0xb3dCcb4Cf7a26f6cf6B120Cf5A73875B7BBc655B;// polygon 0x3d2341ADb2D31f1c5530cDC622016af293177AE0;
    bytes32 public constant KEY_HASH = 0x2ed0feb3e7fd2022120aa84fab1945545a9f2ffc9076fd6156fa96eaff4c1311;// polygon 0xf86195cf7690c55907b2b611ebb7343a6f649bff128701cc542f0569e2c549da;
    
    /**
     * @dev Modulo is the number of equiprobable outcomes in a game so: 2 for coin flip, 6 for dice roll, 
     * 6*6 = 36 for double dice or 37 for roulette
     */
    uint256 constant MAX_MODULO = 100;

    /** 
     * @dev Modulos below MAX_MASK_MODULO are checked against a bit mask, allowing betting on specific outcomes. 
     *
     * For example in a dice roll (modulo = 6), 000001 mask means betting on 1. 000001 converted from binary to
     * decimal becomes 1. 101000 mask means betting on 4 and 6. 101000 converted from binary to decimal becomes
     * 40. The specific value is dictated by the fact that 256-bit intermediate multiplication result allows 
     * implementing population count efficiently for numbers that are up to 42 bits, and 40 is the highest multiple
     * of eight below 42.
     */
    uint256 constant MAX_MASK_MODULO = 40;

    /**
     * @dev This is a check on bet mask overflow. Maximum mask is equivalent to number of possible binary outcomes for maximum modulo.
     */
    uint256 constant MAX_BET_MASK = 2 ** MAX_MASK_MODULO;

    /**
     * @dev These are constants taht make O(1) population count in placeBet possible.
     */
    uint256 constant POPCNT_MULT = 0x0000000000002000000000100000000008000000000400000000020000000001;
    uint256 constant POPCNT_MASK = 0x0001041041041041041041041041041041041041041041041041041041041041;
    uint256 constant POPCNT_MODULO = 0x3F;

    ////////////////
    // STATE
    ////////////////
    
    /**
     * @dev Chainlink fee per bet
     */
    uint256 public chainlinkFee = 0.1 * 10 ** 18;

    /**
     * @dev Each bet is deducted 1% in favor of the house
     */
    uint256 public houseEdgePercent = 1;
    
    /**
     * @dev Sum of all historical deposits and withdrawals. Used for calculating profitability. 
     * Profit = Balance - cumulativeDeposit + cumulativeWithdrawal
     */
    uint256 public cumulativeDeposit;
    uint256 public cumulativeWithdrawal;

    /**
     * @dev In addition to house edge, wealth tax is added every time the bet amount exceeds a multiple of a threshold.
     *
     * For example, if wealthTaxIncrementThreshold = 3000 ether,
     * A bet amount of 3000 ether will have a wealth tax of 1% in addition to house edge.
     * A bet amount of 6000 ether will have a wealth tax of 2% in addition to house edge.
     */
    uint256 public wealthTaxIncrementThreshold = 3000 ether;
    uint256 public wealthTaxIncrementPercent = 1;

    /**
     * @dev The minimum and maximum bets.
     */
    uint256 public minBetAmount = 0.001 ether;
    uint256 public maxBetAmount = 100 ether;

    /**
     * @dev Max bet profit. Used to cap bets against dynamic odds.
     */
    uint256 public maxProfit = 3000 ether;

    /**
     * @dev Funds that are locked in potentially winning bets. Prevents contract from committing to new bets that it cannot pay out.
     */
    uint256 public lockedInBets;

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
     * @dev List of bets
     */
    Bet[] public bets;

    /**
     * @dev Stored number of bets
     */
    uint256 public betsLength;

    /**
     * @dev Mapping requestId returned by Chainlink VRF to bet Id
     */
    mapping(bytes32 => uint256) public betMap;

    ////////////////
    // CONSTRUCTOR
    ////////////////

    constructor()
        VRFConsumerBase(VRF_COORDINATOR, LINK_TOKEN)
    {}
   
    //////////////////////////////////////////////
    // BET RESOLUTION
    //////////////////////////////////////////////

    function placeBet(
        uint256 betMask,
        uint256 modulo
    )
        external
        payable
        nonReentrant
    {
        // Validate input data.
        uint256 amount = msg.value;

        if (LINK.balanceOf(address(this)) < chainlinkFee)
            revert NotEnoughLinkToken();
        if (amount < minBetAmount || maxBetAmount < amount)
            revert BetOutOfRange(amount);

        if (modulo <= 1|| MAX_MODULO < modulo)
            revert ModuloOutOfRange(modulo);
        if (betMask == 0 || MAX_BET_MASK < betMask)
            revert BetMaskOutOfRange(betMask);
            
        uint256 rollUnder;
        uint256 mask;

        if (modulo <= MAX_MASK_MODULO) {
            // rollUnder is a number of 1 bits in this mask (population count). // Small modulo games can specify exact bet outcomes via bit mask.
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

        if (amount + maxProfit < possibleWinAmount)
            revert WinExceedsMaxProfit();
        if (address(this).balance < lockedInBets + possibleWinAmount)
            revert WinExceedsCurrentFunds();

        // Update locked funds
        lockedInBets += possibleWinAmount;

        // Store bet in bet list
        bets.push(Bet(
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
        bytes32 requestId = requestRandomness(KEY_HASH, chainlinkFee);

        // Map requestId to bet ID
        betMap[requestId] = betsLength;

        // Record bet in event logs
        emit BetPlaced(betsLength, msg.sender);

        betsLength++;
    }

    function fulfillRandomness(
        bytes32 requestId,
        uint256 randomness
    )
        internal
        override
    {
        settleBet(requestId, randomness);
    }

    function settleBet(
        bytes32 requestId,
        uint256 randomNumber
    )
        internal
        nonReentrant
    {        
        uint256 betId = betMap[requestId];
        Bet storage bet = bets[betId];
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

        // Unlock possibleWinAmount from lockedInBets, regardless of the outcome.
        lockedInBets -= possibleWinAmount;

        // Update bet records
        bet.isSettled = true;
        bet.winAmount = winAmount;
        bet.randomNumber = randomNumber;
        bet.outcome = outcome;

        // win amount to gambler.
        if (0 < winAmount)
            gambler.transfer(winAmount);
    }

    function refundBet(
        uint256 betId
    )
        external
        nonReentrant
        payable
    {
        Bet storage bet = bets[betId];

        if (bet.amount == 0)
            revert BetNotExist();
        if (bet.isSettled)
            revert BetAlreadySettled();
        if (block.number < bet.placeBlockNumber + 43200)
            revert RefundPeriodNotElapsed();

        uint256 possibleWinAmount = getDiceWinAmount(bet.amount, bet.modulo, bet.rollUnder);
        lockedInBets -= possibleWinAmount;
        bet.isSettled = true;
        bet.winAmount = bet.amount;
        bet.gambler.transfer(bet.amount);

        emit BetRefunded(betId, bet.gambler);
    }
 
    //////////////////////////////////////////////
    // SETTERS
    //////////////////////////////////////////////

    function setHouseEdge(
        uint256 _houseEdgePercent
    )
        external
        onlyOwner
    {
        houseEdgePercent = _houseEdgePercent;
    }

    function setChainlinkFee(
        uint256 _chainlinkFee
    )
        external
        onlyOwner
    {
        chainlinkFee = _chainlinkFee;
    }

    function setMinBetAmount(
        uint256 _minBetAmount
    )
        external
        onlyOwner
    {
        minBetAmount = _minBetAmount;
    }

    function setMaxBetAmount(
        uint256 _maxBetAmount
    )
        external
        onlyOwner
    {
        if (5000000 ether < _maxBetAmount)
            revert InsaneMaxBet();
        maxBetAmount = _maxBetAmount;
    }

    function setMaxProfit(
        uint256 _maxProfit
    )
        external
        onlyOwner
    {
        if (5000000 ether < _maxProfit)
            revert InsaneMaxProfit();
        maxProfit = _maxProfit;
    }

    function setWealthTaxIncrementPercent(
        uint256 _wealthTaxIncrementPercent
    )
        external
        onlyOwner
    {
        wealthTaxIncrementPercent = _wealthTaxIncrementPercent;
    }

    function setWealthTaxIncrementThreshold(
        uint256 _wealthTaxIncrementThreshold
    )
        external
        onlyOwner
    {
        wealthTaxIncrementThreshold = _wealthTaxIncrementThreshold;
    }
 
    //////////////////////////////////////////////
    // GETTERS
    //////////////////////////////////////////////

    function getWealthTax(
        uint256 amount
    )
        private
        view
        returns (uint256 wealthTax)
    {
        wealthTax = amount / wealthTaxIncrementThreshold * wealthTaxIncrementPercent;
    }
 
    function getDiceWinAmount(
        uint256 amount,
        uint256 modulo,
        uint256 rollUnder
    )
        private
        view
        returns (uint256 winAmount)
    {
        if (rollUnder == 0 || modulo < rollUnder)
            revert ProbablityOutOfRange();

        uint256 houseEdge = amount * (houseEdgePercent + getWealthTax(amount)) / 100;
        winAmount = (amount - houseEdge) * modulo / rollUnder;
    }

    function getBalanceETH()
        external
        view
        returns (uint256)
    {
        return address(this).balance;
    }

    function getBalanceLINK()
        external
        view
        returns (uint256)
    {
        return LINK.balanceOf(address(this));
    }

    //////////////////////////////////////////////
    // OWNER FUNCTIONS
    //////////////////////////////////////////////

    function withdrawFunds(
        address payable beneficiary,
        uint256 withdrawAmount
    )
        external
        onlyOwner
    {
        if (address(this).balance < withdrawAmount)
            revert WithdrawExceedsBalance();
        if (address(this).balance - lockedInBets < withdrawAmount)
            revert WithdrawExceedsFreeBalance();
        beneficiary.transfer(withdrawAmount);
        cumulativeWithdrawal += withdrawAmount;
    }

    function withdrawTokens(
        address token_address
    )
        external
        onlyOwner
    {
        IERC20(token_address).safeTransfer(owner(), IERC20(token_address).balanceOf(address(this)));
    }
    
    function withdrawAll()
        external
        onlyOwner
    {
        uint256 withdrawAmount = address(this).balance - lockedInBets;
        cumulativeWithdrawal += withdrawAmount;
        payable(msg.sender).transfer(withdrawAmount);
        IERC20(LINK_TOKEN).safeTransfer(owner(), IERC20(LINK_TOKEN).balanceOf(address(this)));
    }
    
    fallback()
        external
        payable
    {
        cumulativeDeposit += msg.value;
    }

    receive()
        external
        payable
    {
        cumulativeDeposit += msg.value;
    }
}