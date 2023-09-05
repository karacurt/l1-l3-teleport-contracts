// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.13;

import {L1GatewayRouter} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/L1GatewayRouter.sol";
import {AddressAliasHelper} from "@arbitrum/nitro-contracts/src/libraries/AddressAliasHelper.sol";
import {L1ArbitrumMessenger} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/L1ArbitrumMessenger.sol";
import {ClonableBeaconProxy} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/libraries/ClonableBeaconProxy.sol";
import {IInbox} from "@arbitrum/nitro-contracts/src/bridge/IInbox.sol";
import {IL1ArbitrumGateway} from
    "@arbitrum/token-bridge-contracts/contracts/tokenbridge/ethereum/gateway/IL1ArbitrumGateway.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {L2ReceiverFactory} from "./L2ReceiverFactory.sol";

// deploy one of these on L1 for each L2
// bob calls teleport:
// - pulls in tokens and sends them over the bridge to bob's L2Receiver
// - tells the L2ReceiverFactory (via retryable) to create a receiver and bridge for bob
contract Teleporter is L1ArbitrumMessenger {
    struct RetryableGasParams {
        uint256 l2GasPrice;
        uint256 l3GasPrice;
        // gas limit for retryable calling L2ReceiverFactory.bridgeToL3
        uint256 l2ReceiverFactoryGasLimit;
        // gas limit for l1 to l2 token bridge retryable
        uint256 l1l2TokenBridgeGasLimit;
        // gas limit for l2 to l3 token bridge retryable
        uint256 l2l3TokenBridgeGasLimit;
        uint256 l1l2TokenBridgeRetryableSize;
        uint256 l2l3TokenBridgeRetryableSize;
    }

    // todo: needs a better name
    struct RetryableGasResults {
        uint256 l1l2TokenBridgeSubmissionCost;
        uint256 l2ReceiverFactorySubmissionCost;
        uint256 l2l3TokenBridgeSubmissionCost;
        uint256 l1l2TokenBridgeGasCost;
        uint256 l2ReceiverFactoryGasCost;
        uint256 l2l3TokenBridgeGasCost;
        uint256 total;
    }

    bytes32 constant cloneableProxyHash = keccak256(type(ClonableBeaconProxy).creationCode);

    uint256 public constant l2ReceiverFactoryCalldataSize = 4 + 7 * 32; // selector + 7 args

    address public l2ReceiverFactory;
    L1GatewayRouter public l1l2Router;
    IInbox public inbox;

    function initialize(address _l2ReceiverFactory, L1GatewayRouter _l1l2Router, IInbox _inbox) external {
        require(l2ReceiverFactory == address(0), "ALREADY_INIT");
        l2ReceiverFactory = _l2ReceiverFactory;
        l1l2Router = _l1l2Router;
        inbox = _inbox;
    }

    function calculateRetryableGasResults(
        uint256 l1BaseFee,
        RetryableGasParams calldata gasParams
    ) public view returns (RetryableGasResults memory results) {
        // submission costs:
        // on L1: l1l2TokenBridgeSubmissionCost, l2ReceiverFactorySubmissionCost
        // on L2: l2l3TokenBridgeSubmissionCost

        // gas costs:
        // on L1: none
        // on L2: l1l2TokenBridgeGasCost, l2ReceiverFactoryGasCost
        // on L3: l2l3TokenBridgeGasCost

        // msg.value >= l2GasPrice * (l1l2TokenBridgeGasLimit + l2ReceiverFactoryGasLimit)
        //            + l3GasPrice * (l2l3TokenBridgeGasLimit)
        //            + l1l2TokenBridgeSubmissionCost + l2l3TokenBridgeSubmissionCost + l2ReceiverFactorySubmissionCost

        // calculate submission costs
        results.l1l2TokenBridgeSubmissionCost =
            inbox.calculateRetryableSubmissionFee(gasParams.l1l2TokenBridgeRetryableSize, l1BaseFee);
        results.l2ReceiverFactorySubmissionCost =
            inbox.calculateRetryableSubmissionFee(l2ReceiverFactoryCalldataSize, l1BaseFee);
        results.l2l3TokenBridgeSubmissionCost =
            inbox.calculateRetryableSubmissionFee(gasParams.l2l3TokenBridgeRetryableSize, gasParams.l2GasPrice);

        // calculate gas cost for ticket #1 (the l1-l2 token bridge retryable)
        results.l1l2TokenBridgeGasCost = gasParams.l2GasPrice * gasParams.l1l2TokenBridgeGasLimit;

        // calculate gas cost for ticket #2 (call to L2ReceiverFactory.bridgeToL3)
        results.l2ReceiverFactoryGasCost = gasParams.l2GasPrice * gasParams.l2ReceiverFactoryGasLimit;

        // calculate gas cost for ticket #3 (the l2-l3 token bridge retryable)
        results.l2l3TokenBridgeGasCost = gasParams.l3GasPrice * gasParams.l2l3TokenBridgeGasLimit;

        results.total = results.l1l2TokenBridgeSubmissionCost + results.l2ReceiverFactorySubmissionCost
            + results.l2l3TokenBridgeSubmissionCost + results.l1l2TokenBridgeGasCost + results.l2ReceiverFactoryGasCost
            + results.l2l3TokenBridgeGasCost;
    }

    // todo: maybe this should take the l1Gateway as param instead of using the router?
    function teleport(
        address l2l3Router,
        IERC20 l1Token,
        address to,
        uint256 amount,
        RetryableGasParams calldata gasParams
    ) external payable {
        address l2Receiver = predictReceiverAddress(msg.sender);

        // get gateway
        IL1ArbitrumGateway l1Gateway = IL1ArbitrumGateway(l1l2Router.getGateway(address(l1Token)));

        // get l2 token
        address l2Token = l1Gateway.calculateL2TokenAddress(address(l1Token));

        // msg.value accounting checks
        RetryableGasResults memory gasResults =
            calculateRetryableGasResults(block.basefee, gasParams);

        require(msg.value >= gasResults.total, "insufficient msg.value");

        // pull in tokens from bob
        l1Token.transferFrom(msg.sender, address(this), amount);

        // approve gateway
        l1Token.approve(address(l1Gateway), amount);

        // send tokens through the bridge to predicted receiver
        l1l2Router.outboundTransferCustomRefund{
            value: gasResults.l1l2TokenBridgeGasCost + gasResults.l1l2TokenBridgeSubmissionCost
        }(
            address(l1Token),
            l2Receiver,
            l2Receiver,
            amount,
            gasParams.l1l2TokenBridgeGasLimit,
            gasParams.l2GasPrice,
            abi.encode(gasResults.l1l2TokenBridgeSubmissionCost, bytes(""))
        );

        // tell the L2ReceiverFactory to create a receiver and bridge for bob
        bytes memory l2ReceiverFactoryCalldata = abi.encodeWithSelector(
            L2ReceiverFactory.bridgeToL3.selector,
            msg.sender,
            l2l3Router,
            l2Token,
            to,
            amount,
            gasParams.l2l3TokenBridgeGasLimit,
            gasParams.l3GasPrice
        );
        sendTxToL2CustomRefund({
            _inbox: address(inbox),
            _to: l2ReceiverFactory,
            _refundTo: l2Receiver,
            _user: l2Receiver,
            _l1CallValue: address(this).balance, // send everything left
            _l2CallValue: address(this).balance - gasResults.l2ReceiverFactorySubmissionCost
                - gasResults.l2ReceiverFactoryGasCost,
            _maxSubmissionCost: gasResults.l2ReceiverFactorySubmissionCost,
            _maxGas: gasParams.l2ReceiverFactoryGasLimit,
            _gasPriceBid: gasParams.l2GasPrice,
            _data: l2ReceiverFactoryCalldata
        });
    }

    function predictReceiverAddress(address l1Owner) public view returns (address) {
        return Create2.computeAddress(bytes20(l1Owner), cloneableProxyHash, l2ReceiverFactory);
    }
}
