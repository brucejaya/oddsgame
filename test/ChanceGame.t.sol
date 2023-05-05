// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "forge-std/Vm.sol";

import "./utils/Utils.sol";
import "chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";
import "chainlink/contracts/src/v0.8/tests/MockV3Aggregator.sol";
import "chainlink/contracts/src/v0.4/LinkToken.sol";
import "chainlink/contracts/src/v0.8/vrf/VRFV2Wrapper.sol"; 

contract ChanceGameTest is Test {

	// Contracts
    Utils public _utils;
    VRFCoordinatorV2Mock public _vrfCoordinator;
    MockV3Aggregator public _aggregator;
    LinkToken public _link;
    VRFV2Wrapper _vrfWrapper;

    function setUp() public {

        // Get utils
        _utils = new Utils();

        // Create coordinator mock instance
        _vrfCoordinator = new VRFCoordinatorV2Mock();

        // Create coordinator mock instance
        _aggregator = new MockV3Aggregator();

        // Create token mock instance
        _link = new LinkToken();

        // Create wrapper instance
        _vrfWrapper = new VRFV2Wrapper();

        uint256 _wrapperGasOverhead = 6000;
        uint256 _coordinatorGasOverhead = 52000;
        uint256 _wrapperPremiumPercentage = 10;
        bytes32 _keyHash = 0xd89b2bf150e3b9e13446986e571fb9cab24b13cea0a43ea20a6049a85cc807cc;
        uint256 _maxNumWords = 10;

        _vrfWrapper.setConfig(_wrapperGasOverhead, _coordinatorGasOverhead, _wrapperPremiumPercentage, _keyHash, _maxNumWords);

        _vrfCoordinator.addConsumer(uint64 _subId, address _consumer);

    }

}
