// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Lordhold (LHOLD NFT - the stronghold ladder)
/// @notice Lordhold is a medieval kingdom game on BNB Chain. Each
///         wallet climbs a 28-piece ladder of stronghold buildings:
///         piece 1 is FREE, pieces 2-7 cost 0.0002 BNB, 8-14 cost
///         0.0004, 15-21 cost 0.0006, 22-28 cost 0.0008. A full climb
///         costs 0.0138 BNB. Max 28 per wallet, 9,999 pieces in
///         total. Minting requires a Binance Agent ID (SPACE ID).
///
///         Every piece earns LHOLD per hour at a rate set by the tier
///         it was minted on, and each tier fills its share of the
///         wallet's Royal Treasury over its OWN duration:
///           tier 1 (pieces   1-7):  1 LHOLD/hour, fills in 360 hours (15 days)
///           tier 2 (pieces  8-14):  3 LHOLD/hour, fills in 168 hours ( 7 days)
///           tier 3 (pieces 15-21):  6 LHOLD/hour, fills in 120 hours ( 5 days)
///           tier 4 (pieces 22-28): 10 LHOLD/hour, fills in  72 hours ( 3 days)
///         A tier that is full pauses until the Treasury is claimed
///         (claim()); the other tiers keep earning. Claiming pays the
///         whole Treasury out of a fixed emission pocket of
///         300,000,000 LHOLD locked into this contract by the owner.
///         No claim during a wallet's first 3 days (MIN_HOLD) - the
///         first tribute can leave exactly when the LHOLD market
///         opens, on day 3 after the mint opens.
///
///         The LHOLD token trades from its own PancakeSwap pool,
///         which is created on day 3 after the mint opens and funded
///         by the mint fees of the first three days. LHOLD itself is
///         transferable from the first second.
///
///         Earning runs for ONE season of 100 days from the season
///         start set by the owner. When the pocket is empty or the
///         season ends, earning stops for everyone - that rule is
///         published from day one.
///
///         The ladder prices, rates and fill durations are CONSTANTS
///         of this contract. The owner has no function that can
///         change them after deployment.
///
///         Ranks follow the wallet's climb (mintedBy): 1-7 Peasant,
///         8-14 Squire, 15-21 Knight, 22-27 Baron, 28 King.
contract LordholdNFT {
    // ---------------- ERC-721 metadata ----------------
    string public name = "Lordhold";
    string public symbol = "LHOLD";

    // ---------------- Collection / economy constants ----------------
    uint256 public constant MAX_SUPPLY = 9999;
    uint256 public constant MAX_PER_WALLET = 28;
    uint256 public constant ROYALTY_BPS = 500; // 5%
    uint256 public constant OWNER_TEST_CAP = 10;

    // Ladder prices per piece, by the piece's rung inside the wallet
    uint256 public constant PRICE_TIER1 = 0.0002 ether; // rungs 2-7
    uint256 public constant PRICE_TIER2 = 0.0004 ether; // rungs 8-14
    uint256 public constant PRICE_TIER3 = 0.0006 ether; // rungs 15-21
    uint256 public constant PRICE_TIER4 = 0.0008 ether; // rungs 22-28

    // Earning rates (LHOLD wei per hour) per piece, by tier
    uint256 public constant RATE_TIER1 = 1 * 1e18;   // pieces 1-7
    uint256 public constant RATE_TIER2 = 3 * 1e18;   // pieces 8-14
    uint256 public constant RATE_TIER3 = 6 * 1e18;   // pieces 15-21
    uint256 public constant RATE_TIER4 = 10 * 1e18;  // pieces 22-28

    // Fill durations (hours) per tier — each tier fills its own share
    // of the Treasury over its own duration, then pauses.
    uint256 public constant DUR_TIER1 = 360; // 15 days
    uint256 public constant DUR_TIER2 = 168; // 7 days
    uint256 public constant DUR_TIER3 = 120; // 5 days
    uint256 public constant DUR_TIER4 = 72;  // 3 days

    uint256 public constant SEASON_LENGTH = 100 days;
    /// @notice No claim during a wallet's first 3 days: tribute must settle
    ///         in the treasury before the first harvest can leave.
    uint256 public constant MIN_HOLD = 3 days;
    uint256 public constant EMISSION_POCKET = 300_000_000 * 1e18;

    // Mint-fee destination. Starts as the deployer so the contract can
    // be deployed with no constructor arguments; the owner can point
    // it at the project's treasury wallet via setTreasury.
    address public treasury;

    // ---------------- State ----------------
    address public owner;
    bool public paused;
    bool public mintOpen;
    string private _baseURI;

    uint256 public totalMinted;
    uint256 public ownerTestMinted;

    address public crownToken; // LHOLD token contract (set by owner)

    // Binance Agent ID registry (SPACE ID) on BNB Chain
    address public constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    uint256 public seasonStart; // 0 = season not started
    uint256 public emissionPaid; // LHOLD paid out of the pocket so far
    uint256 public totalPending; // LHOLD settled into treasurys, unclaimed

    mapping(uint256 => address) private _owners;
    mapping(address => uint256) private _balances;
    mapping(uint256 => address) private _tokenApprovals;
    mapping(address => mapping(address => bool)) private _operatorApprovals;

    mapping(address => uint256) public mintedBy;
    /// @notice Timestamp of the wallet's first mint (starts the MIN_HOLD).
    mapping(address => uint256) public firstMintAt;
    mapping(uint256 => uint256) public rateOf; // tokenId -> LHOLD wei/hour
    mapping(address => uint256) public crewRate; // wallet -> sum of piece rates held
    mapping(address => uint256[4]) public bandPieces; // wallet -> pieces per tier band
    mapping(address => uint256[4]) public settledBand; // wallet -> settled LHOLD per band
    mapping(address => uint256) public lastSettle; // last accrual timestamp

    uint256 private _lock; // reentrancy guard

    // ---------------- Events ----------------
    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner_, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner_, address indexed operator, bool approved);
    event Minted(address indexed buyer, uint256 indexed tokenId, uint256 rung, uint256 rate);
    event Claimed(address indexed player, uint256 amount);
    event SeasonStarted(uint256 start, uint256 end);
    event CrownTokenSet(address indexed crownToken);
    event TreasurySet(address indexed treasury);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier nonReentrant() {
        require(_lock == 0, "reentrant");
        _lock = 1;
        _;
        _lock = 0;
    }

    constructor() {
        owner = msg.sender;
        treasury = msg.sender;
    }

    // ---------------- ERC-721 core ----------------
    function balanceOf(address a) public view returns (uint256) {
        require(a != address(0), "zero address");
        return _balances[a];
    }

    function ownerOf(uint256 tokenId) public view returns (address) {
        address o = _owners[tokenId];
        require(o != address(0), "nonexistent token");
        return o;
    }

    function approve(address to, uint256 tokenId) public {
        address o = ownerOf(tokenId);
        require(msg.sender == o || _operatorApprovals[o][msg.sender], "not authorized");
        _tokenApprovals[tokenId] = to;
        emit Approval(o, to, tokenId);
    }

    function getApproved(uint256 tokenId) public view returns (address) {
        require(_owners[tokenId] != address(0), "nonexistent token");
        return _tokenApprovals[tokenId];
    }

    function setApprovalForAll(address operator, bool approved) public {
        _operatorApprovals[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function isApprovedForAll(address o, address operator) public view returns (bool) {
        return _operatorApprovals[o][operator];
    }

    function transferFrom(address from, address to, uint256 tokenId) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not authorized");
        _transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) public {
        safeTransferFrom(from, to, tokenId, "");
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory data) public {
        require(_isApprovedOrOwner(msg.sender, tokenId), "not authorized");
        _transfer(from, to, tokenId);
        require(_checkOnERC721Received(from, to, tokenId, data), "receiver rejected");
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address o = ownerOf(tokenId);
        return spender == o || _tokenApprovals[tokenId] == spender || _operatorApprovals[o][spender];
    }

    function _transfer(address from, address to, uint256 tokenId) internal {
        require(ownerOf(tokenId) == from, "wrong from");
        require(to != address(0), "zero to");
        // Settle both treasurys before the crew changes hands.
        _settle(from);
        _settle(to);
        _tokenApprovals[tokenId] = address(0);
        _balances[from] -= 1;
        _balances[to] += 1;
        _owners[tokenId] = to;
        uint256 r = rateOf[tokenId];
        crewRate[from] -= r;
        crewRate[to] += r;
        uint256 b = bandOfRate(r);
        bandPieces[from][b] -= 1;
        bandPieces[to][b] += 1;
        emit Transfer(from, to, tokenId);
    }

    function _checkOnERC721Received(address from, address to, uint256 tokenId, bytes memory data) private returns (bool) {
        if (to.code.length > 0) {
            try IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) returns (bytes4 retval) {
                return retval == IERC721Receiver.onERC721Received.selector;
            } catch {
                return false;
            }
        }
        return true;
    }

    function supportsInterface(bytes4 interfaceId) public pure returns (bool) {
        return interfaceId == 0x80ac58cd // ERC-721
            || interfaceId == 0x5b5e139f // ERC-721 metadata
            || interfaceId == 0x2a55205a // ERC-2981 royalties
            || interfaceId == 0x01ffc9a7; // ERC-165
    }

    /// @notice ERC-2981 royalty: 5% to the treasury on every secondary sale
    function royaltyInfo(uint256, uint256 salePrice) public view returns (address, uint256) {
        return (treasury, (salePrice * ROYALTY_BPS) / 10000);
    }

    // ---------------- Metadata ----------------
    function tokenURI(uint256 tokenId) public view returns (string memory) {
        require(_owners[tokenId] != address(0), "nonexistent token");
        return string(abi.encodePacked(_baseURI, _toString(tokenId), ".json"));
    }

    function _toString(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 t = v;
        uint256 digits;
        while (t != 0) { digits++; t /= 10; }
        bytes memory b = new bytes(digits);
        while (v != 0) { digits--; b[digits] = bytes1(uint8(48 + (v % 10))); v /= 10; }
        return string(b);
    }

    // ---------------- Ladder math ----------------
    /// @notice Price of the piece at a given rung (1-based) in a wallet's climb.
    function priceForRung(uint256 rung) public pure returns (uint256) {
        if (rung <= 1) return 0;
        if (rung <= 7) return PRICE_TIER1;
        if (rung <= 14) return PRICE_TIER2;
        if (rung <= 21) return PRICE_TIER3;
        return PRICE_TIER4;
    }

    /// @notice Earning rate (LHOLD wei/hour) of the piece at a given rung.
    function rateForRung(uint256 rung) public pure returns (uint256) {
        if (rung <= 7) return RATE_TIER1;
        if (rung <= 14) return RATE_TIER2;
        if (rung <= 21) return RATE_TIER3;
        return RATE_TIER4;
    }

    /// @notice Tier band index (0-3) of a given rung.
    function bandOfRung(uint256 rung) public pure returns (uint256) {
        if (rung <= 7) return 0;
        if (rung <= 14) return 1;
        if (rung <= 21) return 2;
        return 3;
    }

    /// @notice Tier band index (0-3) of a piece with the given rate.
    function bandOfRate(uint256 rate) public pure returns (uint256) {
        if (rate <= RATE_TIER1) return 0;
        if (rate <= RATE_TIER2) return 1;
        if (rate <= RATE_TIER3) return 2;
        return 3;
    }

    /// @notice Earning rate (LHOLD wei/hour) per piece of a band.
    function rateForBand(uint256 band) public pure returns (uint256) {
        if (band == 0) return RATE_TIER1;
        if (band == 1) return RATE_TIER2;
        if (band == 2) return RATE_TIER3;
        return RATE_TIER4;
    }

    /// @notice Fill duration (hours) of a band.
    function durationForBand(uint256 band) public pure returns (uint256) {
        if (band == 0) return DUR_TIER1;
        if (band == 1) return DUR_TIER2;
        if (band == 2) return DUR_TIER3;
        return DUR_TIER4;
    }

    /// @notice Total cost for a wallet that has already minted `already`
    ///         pieces to mint `qty` more, walking the ladder rung by rung.
    function quoteMint(address wallet, uint256 qty) public view returns (uint256 cost) {
        uint256 already = mintedBy[wallet];
        for (uint256 i = 1; i <= qty; i++) {
            cost += priceForRung(already + i);
        }
    }

    /// @notice Rank index by climb: 0 Peasant (1-7), 1 Squire
    ///         (8-14), 2 Knight (15-21), 3 Baron
    ///         (22-27), 4 King (28).
    function rankOf(address wallet) public view returns (uint256) {
        uint256 m = mintedBy[wallet];
        if (m >= 28) return 4;
        if (m >= 22) return 3;
        if (m >= 15) return 2;
        if (m >= 8) return 1;
        return 0;
    }

    /// @notice When this wallet's first claim unlocks (0 = no hold applies).
    function claimOpensAt(address wallet) external view returns (uint256) {
        uint256 t = firstMintAt[wallet];
        return t == 0 ? 0 : t + MIN_HOLD;
    }

    function isKing(address wallet) public view returns (bool) {
        return mintedBy[wallet] >= MAX_PER_WALLET;
    }

    // ---------------- Season / earning ----------------
    function seasonEnd() public view returns (uint256) {
        return seasonStart == 0 ? 0 : seasonStart + SEASON_LENGTH;
    }

    function seasonActive() public view returns (bool) {
        return seasonStart != 0 && block.timestamp >= seasonStart && block.timestamp < seasonEnd();
    }

    function emissionRemaining() public view returns (uint256) {
        uint256 used = emissionPaid + totalPending;
        return used >= EMISSION_POCKET ? 0 : EMISSION_POCKET - used;
    }

    /// @notice Treasury capacity of a wallet: the sum over its tier
    ///         bands of pieces x rate x that band's fill duration.
    function treasuryCapacityOf(address wallet) public view returns (uint256) {
        uint256 cap;
        for (uint256 b = 0; b < 4; b++) {
            cap += bandPieces[wallet][b] * rateForBand(b) * durationForBand(b);
        }
        return cap;
    }

    /// @notice LHOLD already settled into the wallet's Treasury.
    function treasuryOf(address wallet) public view returns (uint256) {
        return settledBand[wallet][0] + settledBand[wallet][1]
            + settledBand[wallet][2] + settledBand[wallet][3];
    }

    /// @notice LHOLD a wallet could claim right now (view only).
    function pendingOf(address wallet) public view returns (uint256) {
        uint256[4] memory adds = _bandAdds(wallet);
        return treasuryOf(wallet) + adds[0] + adds[1] + adds[2] + adds[3];
    }

    /// @notice Per-band LHOLD accrued since the last settle, each
    ///         band capped by its own remaining room (capacity minus
    ///         what is already settled in that band), and the total
    ///         capped by what is left in the emission pocket. Bands
    ///         are filled in order 0..3 when the pocket runs dry.
    function _bandAdds(address wallet) internal view returns (uint256[4] memory adds) {
        if (!seasonActive()) return adds;
        uint256 from = lastSettle[wallet];
        if (from < seasonStart) from = seasonStart;
        if (block.timestamp <= from) return adds;
        uint256 elapsed = block.timestamp - from;
        uint256 pocket = emissionRemaining();
        for (uint256 b = 0; b < 4; b++) {
            uint256 pieces = bandPieces[wallet][b];
            if (pieces == 0) continue;
            uint256 rate = rateForBand(b);
            uint256 window = durationForBand(b) * 3600;
            uint256 span = elapsed < window ? elapsed : window;
            uint256 amount = (pieces * rate * span) / 3600;
            uint256 room = pieces * rate * durationForBand(b);
            uint256 settled = settledBand[wallet][b];
            if (settled >= room) continue;
            room -= settled;
            if (amount > room) amount = room;
            if (amount > pocket) amount = pocket;
            pocket -= amount;
            adds[b] = amount;
        }
    }

    /// @notice Fold everything loaded since the last settle into the
    ///         wallet's Treasury, per band.
    function _settle(address wallet) internal {
        uint256[4] memory adds = _bandAdds(wallet);
        uint256 total;
        for (uint256 b = 0; b < 4; b++) {
            if (adds[b] > 0) {
                settledBand[wallet][b] += adds[b];
                total += adds[b];
            }
        }
        if (total > 0) totalPending += total;
        lastSettle[wallet] = block.timestamp;
    }

    /// @notice Anyone can settle their own Treasury without claiming.
    function settle() external {
        _settle(msg.sender);
    }

    /// @notice Claim: pay out the wallet's whole Treasury in LHOLD
    ///         from this contract's emission balance.
    function claim() external nonReentrant {
        require(
            firstMintAt[msg.sender] == 0 ||
                block.timestamp >= firstMintAt[msg.sender] + MIN_HOLD,
            "tribute is still settling (3-day hold)"
        );
        _settle(msg.sender);
        uint256 amount = treasuryOf(msg.sender);
        require(amount > 0, "treasury empty");
        require(crownToken != address(0), "crown not set");
        settledBand[msg.sender] = [uint256(0), 0, 0, 0];
        totalPending -= amount;
        emissionPaid += amount;
        require(ICrownToken(crownToken).transfer(msg.sender, amount), "crown transfer failed");
        emit Claimed(msg.sender, amount);
    }

    // ---------------- Mint ----------------
    function mintLive() public view returns (bool) {
        return !paused && mintOpen && seasonActive();
    }

    function _mintOne(address to, uint256 rung) internal returns (uint256 tokenId) {
        totalMinted += 1;
        tokenId = totalMinted;
        _owners[tokenId] = to;
        _balances[to] += 1;
        uint256 rate = rateForRung(rung);
        rateOf[tokenId] = rate;
        crewRate[to] += rate;
        bandPieces[to][bandOfRung(rung)] += 1;
        emit Transfer(address(0), to, tokenId);
        emit Minted(to, tokenId, rung, rate);
    }

    /// @notice True when the wallet holds a Binance Agent ID (SPACE ID).
    function hasAgentId(address wallet) public view returns (bool) {
        return IAgentIdRegistry(AGENT_ID_REGISTRY).balanceOf(wallet) > 0;
    }

    /// @notice Public mint: climb the ladder. The first piece is free;
    ///         every further piece is priced by its rung. The exact
    ///         total is forwarded to the treasury; any excess value is
    ///         refunded in the same transaction. Open to every wallet.
    function mint(uint256 qty) public payable nonReentrant {
        require(mintLive(), "mint not open");
        require(hasAgentId(msg.sender), "Agent ID required");
        require(qty >= 1, "bad qty");
        require(mintedBy[msg.sender] + qty <= MAX_PER_WALLET, "wallet cap reached");
        require(totalMinted + qty <= MAX_SUPPLY, "sold out");
        uint256 cost = quoteMint(msg.sender, qty);
        require(msg.value >= cost, "value too low");

        _settle(msg.sender);
        if (mintedBy[msg.sender] == 0) firstMintAt[msg.sender] = block.timestamp;
        uint256 startRung = mintedBy[msg.sender];
        mintedBy[msg.sender] += qty;
        if (cost > 0) {
            (bool okT, ) = payable(treasury).call{value: cost}("");
            require(okT, "treasury send failed");
        }
        if (msg.value > cost) {
            (bool okR, ) = payable(msg.sender).call{value: msg.value - cost}("");
            require(okR, "refund failed");
        }
        for (uint256 i = 1; i <= qty; i++) {
            _mintOne(msg.sender, startRung + i);
        }
    }

    /// @notice Owner test mints before the public opening. Hard capped,
    ///         minted to the owner only, counted inside the 9,999
    ///         supply. Test pieces sit on rungs 1..qty of the owner's
    ///         own climb record without consuming the owner's public
    ///         paid quota beyond those rungs.
    function ownerMint(uint256 qty) external onlyOwner {
        require(qty >= 1, "bad qty");
        require(ownerTestMinted + qty <= OWNER_TEST_CAP, "test cap reached");
        require(totalMinted + qty <= MAX_SUPPLY, "sold out");
        _settle(msg.sender);
        uint256 startRung = mintedBy[msg.sender];
        ownerTestMinted += qty;
        mintedBy[msg.sender] += qty;
        for (uint256 i = 1; i <= qty; i++) {
            _mintOne(msg.sender, startRung + i);
        }
    }

    // ---------------- Owner (setup + emergency only) ----------------
    function setBaseURI(string calldata uri) external onlyOwner {
        _baseURI = uri;
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
    }

    function setMintOpen(bool open) external onlyOwner {
        mintOpen = open;
    }

    /// @notice Point mint fees (and ERC-2981 royalties) at a new
    ///         treasury wallet. Owner only.
    function setTreasury(address treasury_) external onlyOwner {
        require(treasury_ != address(0), "treasury zero");
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    /// @notice Point the NFT contract at the LHOLD token. The owner
    ///         must also fund this contract with the 250,000,000
    ///         LHOLD emission pocket before the season starts.
    function setCrownToken(address token) external onlyOwner {
        require(token != address(0), "token zero");
        crownToken = token;
        emit CrownTokenSet(token);
    }

    /// @notice Start Season 1: 100 days of earning from this moment.
    ///         One-way: the season can never be restarted or extended.
    function startSeason() external onlyOwner {
        require(seasonStart == 0, "season already started");
        require(crownToken != address(0), "crown not set");
        seasonStart = block.timestamp;
        emit SeasonStarted(seasonStart, seasonEnd());
    }

    /// @notice Recover LHOLD sent to this contract beyond the
    ///         emission pocket accounting (e.g. an over-funding
    ///         surplus) — only the surplus above what treasurys plus
    ///         the unpaid pocket need.
    function withdrawCrownSurplus(uint256 amount) external onlyOwner {
        uint256 balance = ICrownToken(crownToken).balanceOf(address(this));
        uint256 reserved = totalPending + emissionRemaining();
        require(balance >= reserved + amount, "surplus too low");
        require(ICrownToken(crownToken).transfer(owner, amount), "crown transfer failed");
    }
}

interface IERC721Receiver {
    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data) external returns (bytes4);
}

interface ICrownToken {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}


interface IAgentIdRegistry {
    function balanceOf(address account) external view returns (uint256);
}
