// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "./interfaces/IGaugeProxy.sol";
import "./base/BaseGaugeController.sol";
import "./base/BaseNFTs.sol";
import "./libraries/Base64.sol";

contract NFTGauge is BaseGaugeController, BaseNFTs {
    using Address for address;
    using Strings for uint256;

    bytes16 private constant _HEX_SYMBOLS = "0123456789abcdef";

    address public proxy;
    address public controller;
    address public nftContract;
    string public color;
    string internal _name;

    mapping(uint256 => bool) public withdrawn;

    function initialize(address _nftContract) external initializer {
        proxy = msg.sender;
        controller = IGaugeProxy(proxy).controller();
        nftContract = _nftContract;
        color = _toColor(nftContract);

        __BaseGaugeController_init(
            IBaseGaugeController(controller).interval(),
            IBaseGaugeController(controller).weightVoteDelay(),
            IBaseGaugeController(controller).votingEscrow()
        );

        string memory symbol;
        try IERC721Metadata(_nftContract).name() returns (string memory name) {
            _name = name;
        } catch {
            _name = uint256(uint160(nftContract)).toHexString(20);
        }
        try IERC721Metadata(_nftContract).symbol() returns (string memory _symbol) {
            symbol = string(abi.encodePacked("W", _symbol));
        } catch {
            symbol = "WNFT";
        }
        __BaseNFTs_init(string(abi.encodePacked("Wrapped ", _name)), symbol);

        _addType("NFTs", 10**18);
    }

    function _toColor(address addr) internal pure returns (string memory) {
        uint160 value = uint160(addr);
        bytes memory buffer = new bytes(7);
        for (uint256 i = 6; i > 0; --i) {
            buffer[i] = _HEX_SYMBOLS[value & 0xf];
            value >>= 4;
        }
        require(value == 0, "NFTG: HEX_LENGTH_INSUFFICIENT");
        return string(buffer);
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory output) {
        require(_exists(tokenId), "NFTG: TOKEN_NON_EXISTENT");

        output = string(
            abi.encodePacked(
                '<svg width="600px" height="600px" viewBox="0 0 600 600" version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><defs><polygon points="0 0 200 0 200 232 0 232"></polygon></defs><g stroke="none" stroke-width="1" fill="none" fill-rule="evenodd"><g><rect fill="#FFFFFF" fill-rule="nonzero" x="0" y="0" width="600" height="599.999985"></rect><rect fill="',
                color,
                '" fill-rule="nonzero" x="0" y="0" width="600" height="599.999985"></rect><g transform="translate(79.843749, 99.999999)"><g><mask fill="white"><use xlink:href="#path-1"></use></mask><g></g><path d="M199.578125,146.468749 C199.578125,146.119792 199.442709,145.786459 199.192709,145.536459 L165.875,112.161459 L191.755209,86.2239587 C191.947917,86.0468747 192.062501,85.8125 192.114584,85.5625 L199.546876,48.5260413 C199.557292,48.494792 199.505209,48.4739587 199.505209,48.432292 C199.557292,48.0364587 199.494792,47.635416 199.192709,47.3333333 L153.432292,1.48437467 C152.942709,0.989584 152.072917,0.989584 151.578125,1.48437467 L103.505209,49.6718747 L55.432292,1.48437467 C54.9427093,0.989584 54.0729173,1 53.5781253,1.494792 L7.81770933,47.4583333 C7.671876,47.5937493 7.671876,47.7812507 7.609376,47.9583333 C7.57812533,48.0364587 7.47395867,48.0468747 7.45312533,48.119792 L0.0208346667,85.260416 C-0.0624986667,85.6875 0.0625013333,86.130208 0.375,86.442708 L33.5781253,119.713541 L7.807292,145.536459 C7.671876,145.671875 7.66145867,145.869792 7.59895867,146.046875 C7.56770933,146.119792 7.46354267,146.130208 7.45312533,146.218749 L0.0208346667,183.359375 C-0.0624986667,183.786459 0.0625013333,184.229167 0.375,184.541667 L46.1354173,230.390625 C46.1979173,230.453125 46.302084,230.442708 46.3854173,230.494792 C46.427084,230.526041 46.3958347,230.593749 46.4479173,230.625 C46.6458347,230.729167 46.859376,230.781251 47.0677093,230.781251 C47.1927093,230.781251 47.3177093,230.760416 47.4427093,230.729167 C47.5260427,230.708333 47.5260427,230.593749 47.5989587,230.552083 C47.7239587,230.484375 47.8854173,230.494792 47.989584,230.380208 L96.0208347,182.171875 L144.156251,230.390625 C144.218751,230.453125 144.322917,230.442708 144.406251,230.494792 C144.447917,230.526041 144.416667,230.593749 144.468751,230.625 C144.666667,230.729167 144.880209,230.781251 145.088543,230.781251 C145.213543,230.781251 145.338543,230.760416 145.463543,230.718749 C145.536459,230.697917 145.536459,230.604167 145.598959,230.572917 C145.734376,230.505208 145.906251,230.505208 146.010417,230.401041 L191.765625,184.552083 C191.958333,184.364584 192.072917,184.135416 192.125,183.880208 L199.557292,146.739584 C199.567709,146.708333 199.515625,146.6875 199.515625,146.645833 C199.515625,146.583333 199.578125,146.531251 199.578125,146.468749 Z M189.630209,84.6614587 L164.031251,110.3125 L151.119792,97.375 L196.135417,52.2708333 L189.630209,84.6614587 Z M49.2031253,225.463541 L55.7031253,192.979167 L78.984376,169.656251 L101.421876,147.171875 L94.9010427,179.588541 L49.2031253,225.463541 Z M189.630209,182.968749 L147.203125,225.484375 L151.286459,204.833333 L153.609376,193.083333 L196.135417,150.473959 L189.630209,182.968749 Z M152.406251,190.567708 L104.427084,142.489584 C104.427084,142.489584 104.427084,142.489584 104.416667,142.489584 L104.291667,142.364584 C104.041667,142.135416 103.713543,142.010416 103.390625,142.010416 C103.057292,142.010416 102.718751,142.145833 102.468751,142.385416 L54.489584,190.458333 L10.5833333,146.468749 L36.354168,120.656251 C36.354168,120.656251 36.364584,120.656251 36.364584,120.656251 L58.5625013,98.4166667 C59.0781253,97.9010413 59.0781253,97.0729173 58.5625013,96.557292 L10.5937507,48.380208 L54.5,4.27083333 L102.583333,52.4635413 C103.078125,52.9531253 103.947917,52.9531253 104.437501,52.4635413 L152.520835,4.27083333 L196.427084,48.2656253 L181.234376,63.5 L148.354168,96.442708 C148.093751,96.692708 147.958333,97.0416667 147.958333,97.375 C147.958333,97.7135413 148.083333,98.0468747 148.343751,98.3020827 L163.109376,113.093749 C163.109376,113.104167 163.109376,113.104167 163.109376,113.104167 L196.416667,146.468749 L152.406251,190.567708 Z" fill="#FFFFFF" fill-rule="nonzero" mask="url(#mask-2)"></path></g><path d="M147.958333,97.375 C147.958333,97.0416667 148.083333,96.7031253 148.343751,96.442708 L181.223959,63.5 L196.416667,48.2656253 L152.510417,4.27083333 L104.437501,52.4635413 C103.947917,52.9531253 103.078125,52.9531253 102.583333,52.4635413 L54.5,4.27083333 L10.5937507,48.380208 L58.5729173,96.557292 C59.0885427,97.0729173 59.0885427,97.9010413 58.5729173,98.4166667 L36.375,120.656251 C36.375,120.656251 36.364584,120.656251 36.364584,120.656251 L10.5937507,146.468749 L54.5,190.458333 L102.479168,142.385416 C102.729168,142.145833 103.067709,142.010416 103.401043,142.010416 C103.723959,142.010416 104.052084,142.135416 104.302084,142.364584 L104.427084,142.489584 C104.427084,142.489584 104.427084,142.489584 104.437501,142.489584 L152.416667,190.567708 L196.427084,146.468749 L163.119792,113.104167 C163.119792,113.104167 163.119792,113.104167 163.119792,113.093749 L148.354168,98.3020827 C148.093751,98.0468747 147.958333,97.7135413 147.958333,97.375 Z" fill="',
                color,
                '" fill-rule="nonzero"></path></g></g><text font-family="Arial-BoldMT, Arial" font-size="48" font-weight="bold" fill="#FFFFFF"><tspan x="79.5" y="404">Wrapped</tspan><tspan x="79.5" y="457">',
                _name,
                '</tspan><tspan x="79.5" y="510">#',
                tokenId.toString(),
                "</tspan></text></g></svg>"
            )
        );

        string memory json = Base64.encode(
            bytes(
                string(
                    abi.encodePacked(
                        '{"name": "',
                        name(),
                        " #",
                        tokenId.toString(),
                        '", "description": "Wrapped NFT that earns passive LEVX yield in proportional to the THANO$ staked together", "image": "data:image/svg+xml;base64,',
                        Base64.encode(bytes(output)),
                        '"}'
                    )
                )
            )
        );
        output = string(abi.encodePacked("data:application/json;base64,", json));
    }

    function deposit(address to, uint256 tokenId) public {
        bytes32 id = bytes32(tokenId);
        if (_gaugeTypes[id] == 0) {
            _addGauge(id, 0);
        }
        withdrawn[tokenId] = false;

        _mint(to, tokenId);
        IERC721(nftContract).safeTransferFrom(msg.sender, address(this), tokenId);
    }

    function withdraw(address to, uint256 tokenId) public {
        require(ownerOf(tokenId) == msg.sender, "NFTG: FORBIDDEN");

        _changeGaugeWeight(bytes32(tokenId), 0);
        withdrawn[tokenId] = true;

        _burn(tokenId);
        IERC721(nftContract).safeTransferFrom(address(this), to, tokenId);
    }

    function voteForGaugeWeights(uint256 tokenId, uint256 userWeight) external {
        require(!withdrawn[tokenId], "NFTG: WITHDRAWN");

        _voteForGaugeWeights(bytes32(tokenId), msg.sender, userWeight);
    }
}
