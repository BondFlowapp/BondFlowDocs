// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

interface IEngineVault {
    function fundInflowFromVault(uint256 amount) external;
}

interface IPositionEngineView {
    function tvl() external view returns (uint256);
    function vaultAllocBps() external view returns (uint16);
}

interface IERC20Decimals is IERC20 {
    function decimals() external view returns (uint8);
}

interface IPositionVault {
    function provideLiquidity(uint256 amountUsdc) external;
}

contract BondFlow is
    ERC721Enumerable,
    ReentrancyGuard,
    Ownable,
    IEngineVault,
    IPositionEngineView
{
    using SafeERC20 for IERC20Decimals;
    using Strings for uint256;

    IERC20Decimals public immutable usdc;
    address public vault;
    uint16 private _vaultAllocBps;

    address public immutable marketing1;
    address public immutable marketing2;
    address public immutable marketing3;
    address public immutable marketing4;

    uint16 public constant MARKETING1_BPS = 300;
    uint16 public constant MARKETING2_BPS = 300;
    uint16 public constant MARKETING3_BPS = 300;
    uint16 public constant MARKETING4_BPS = 100;

    uint256 public constant MAX_INDIRECT_REFERRALS = 1000;

    uint16 public constant LOTTERY_BPS = 100;
    uint256 public constant TICKET_UNIT = 100e6;

    struct Plan {
        uint64 lockTime;
        uint16 returnBps;
        bool   active;
    }

    Plan[4] public plans;

    struct Bond {
        uint256 principal;
        uint256 payout;
        uint64  startTime;
        uint64  endTime;
        uint8   planId;
        bool    claimed;
    }

    mapping(uint256 => Bond) public bonds;
    mapping(address => address) public referrerOf;
    mapping(address => uint256) public volumePersonal;
    mapping(address => uint256) public volumeNetwork;
    mapping(address => uint256) public referralRewards;

    mapping(address => address[]) public directReferrals;

    mapping(address => string) public referralNameOf;
    mapping(bytes32 => address) public referralNameOwner;

    uint256 public totalPrincipalActive;
    string private _baseTokenURI;

    uint256 public lotteryPool;
    uint256 public lotteryRound;
    uint64  public lotteryRoundStart;
    address public lastLotteryWinner;

    mapping(uint256 => mapping(address => uint256)) public userTicketsPerRound;
    mapping(uint256 => address[]) private roundParticipants;
    mapping(uint256 => mapping(address => bool)) private isParticipantInRound;

    string[4] private _planURIs;

    event BondPurchased(address indexed user,uint256 indexed tokenId,uint8 planId,uint256 principal,uint256 payout,uint64 endTime,address indexed referrer);
    event BondClaimed(address indexed user,uint256 indexed tokenId,uint256 payout);
    event ReferrerSet(address indexed user,address indexed referrer);
    event DirectReferralAdded(address indexed referrer,address indexed user);
    event ReferralRewardAccrued(address indexed user,uint256 amount);
    event ReferralRewardClaimed(address indexed user,uint256 amount);
    event ReferralNameSet(address indexed user,string name);
    event VaultSet(address vault);
    event VaultAllocBpsSet(uint16 bps);
    event InflowFromVault(uint256 amount);
    event BaseURISet(string newBaseURI);
    event LotteryTicketsIssued(address indexed user,uint256 indexed round,uint256 tickets,uint256 amountUsdc);
    event LotteryWinner(uint256 indexed round,address indexed winner,uint256 amount,uint256 totalTickets);
    event LotteryRoundStarted(uint256 indexed round,uint64 startTime);

    constructor(
        address _usdc,
        address _marketing1,
        address _marketing2,
        address _marketing3,
        address _marketing4
    )
        ERC721("BondFlow Bond", "BOND")
        Ownable(msg.sender)
    {
        usdc = IERC20Decimals(_usdc);
        marketing1 = _marketing1;
        marketing2 = _marketing2;
        marketing3 = _marketing3;
        marketing4 = _marketing4;

        plans[0] = Plan({lockTime: 1 days, returnBps: 30, active: true});
        plans[1] = Plan({lockTime: 7 days, returnBps: 300, active: true});
        plans[2] = Plan({lockTime: 14 days, returnBps: 712, active: true});
        plans[3] = Plan({lockTime: 28 days, returnBps: 1800, active: true});

        _vaultAllocBps = 10000;

        lotteryRound = 1;
        lotteryRoundStart = uint64(block.timestamp);
        emit LotteryRoundStarted(lotteryRound, lotteryRoundStart);
    }

    function setBaseURI(string calldata newBaseURI) external onlyOwner {
        _baseTokenURI = newBaseURI;
        emit BaseURISet(newBaseURI);
    }

    function _baseURI() internal view override returns (string memory) {
        return _baseTokenURI;
    }

    function setPlanURI(uint8 planId, string calldata uri) external onlyOwner {
        require(planId < plans.length, "PLAN");
        _planURIs[planId] = uri;
    }

    function setVault(address _vault) external onlyOwner {
        vault = _vault;
        emit VaultSet(_vault);
    }

    function setVaultAllocBps(uint16 bps) external onlyOwner {
        require(bps <= 10000, "BPS");
        _vaultAllocBps = bps;
        emit VaultAllocBpsSet(bps);
    }

    function setPlan(uint8 planId,uint64 lockTime,uint16 returnBps,bool active) external onlyOwner {
        require(planId < plans.length, "PLAN");
        plans[planId] = Plan(lockTime, returnBps, active);
    }

    function setReferralName(string calldata name) external {
        _maybeDrawLottery();
        bytes memory n = bytes(name);
        require(n.length > 0 && n.length <= 32, "NAME_LEN");
        require(bytes(referralNameOf[msg.sender]).length == 0, "NAME_SET");
        bytes32 h = keccak256(n);
        require(referralNameOwner[h] == address(0), "NAME_TAKEN");
        referralNameOwner[h] = msg.sender;
        referralNameOf[msg.sender] = name;
        emit ReferralNameSet(msg.sender, name);
    }

    function getAddressByReferralName(string calldata name) external view returns (address) {
        return referralNameOwner[keccak256(bytes(name))];
    }

    function _setReferrer(address user, address _referrer) internal {
        if (_referrer != address(0) && _referrer != user && referrerOf[user] == address(0)) {
            address current = _referrer;
            for (uint256 i = 0; i < 50 && current != address(0); i++) {
                require(current != user, "REFERRAL_CYCLE");
                current = referrerOf[current];
            }
            referrerOf[user] = _referrer;
            directReferrals[_referrer].push(user);
            emit ReferrerSet(user, _referrer);
            emit DirectReferralAdded(_referrer, user);
        }
    }

    function _handleMarketing(uint256 amountUsdc) internal returns (uint256) {
        uint256 totalMarketing;

        uint256 m1 = (amountUsdc * MARKETING1_BPS) / 10000;
        if (m1 > 0) { totalMarketing += m1; usdc.safeTransfer(marketing1, m1); }

        uint256 m2 = (amountUsdc * MARKETING2_BPS) / 10000;
        if (m2 > 0) { totalMarketing += m2; usdc.safeTransfer(marketing2, m2); }

        uint256 m3 = (amountUsdc * MARKETING3_BPS) / 10000;
        if (m3 > 0) { totalMarketing += m3; usdc.safeTransfer(marketing3, m3); }

        uint256 m4 = (amountUsdc * MARKETING4_BPS) / 10000;
        if (m4 > 0) { totalMarketing += m4; usdc.safeTransfer(marketing4, m4); }

        return amountUsdc - totalMarketing;
    }

    function _handleLotteryOnBondPurchase(address user, uint256 amountUsdc, uint256 baseAmount)
        internal
        returns (uint256 allocatableAfterLottery)
    {
        uint256 lotteryAmt = (amountUsdc * LOTTERY_BPS) / 10000;
        allocatableAfterLottery = baseAmount;
        if (lotteryAmt > allocatableAfterLottery) {
            lotteryAmt = allocatableAfterLottery;
        }
        if (lotteryAmt > 0) {
            allocatableAfterLottery -= lotteryAmt;
            lotteryPool += lotteryAmt;
        }

        if (amountUsdc >= TICKET_UNIT) {
            uint256 tickets = amountUsdc / TICKET_UNIT;
            if (tickets > 0) {
                userTicketsPerRound[lotteryRound][user] += tickets;

                if (!isParticipantInRound[lotteryRound][user]) {
                    isParticipantInRound[lotteryRound][user] = true;
                    roundParticipants[lotteryRound].push(user);
                }

                emit LotteryTicketsIssued(user, lotteryRound, tickets, amountUsdc);
            }
        }
    }

    function _maybeDrawLottery() internal {
        if (block.timestamp < lotteryRoundStart + 1 days) return;

        uint256 pool = lotteryPool;
        address[] storage participants = roundParticipants[lotteryRound];

        if (participants.length == 0 || pool == 0) {
            for (uint256 i = 0; i < participants.length; i++) {
                address a = participants[i];
                userTicketsPerRound[lotteryRound][a] = 0;
                isParticipantInRound[lotteryRound][a] = false;
            }
            delete roundParticipants[lotteryRound];
            lotteryRound += 1;
            lotteryRoundStart = uint64(block.timestamp);
            emit LotteryRoundStarted(lotteryRound, lotteryRoundStart);
            return;
        }

        uint256 totalTickets;
        for (uint256 i = 0; i < participants.length; i++) {
            totalTickets += userTicketsPerRound[lotteryRound][participants[i]];
        }

        if (totalTickets == 0) {
            for (uint256 i = 0; i < participants.length; i++) {
                address a = participants[i];
                userTicketsPerRound[lotteryRound][a] = 0;
                isParticipantInRound[lotteryRound][a] = false;
            }
            delete roundParticipants[lotteryRound];
            lotteryRound += 1;
            lotteryRoundStart = uint64(block.timestamp);
            emit LotteryRoundStarted(lotteryRound, lotteryRoundStart);
            return;
        }

        uint256 rand = uint256(
            keccak256(
                abi.encodePacked(
                    block.timestamp,
                    block.prevrandao,
                    participants.length,
                    totalTickets,
                    pool
                )
            )
        );
        uint256 winningTicket = rand % totalTickets;

        address winner;
        uint256 cumulative;
        for (uint256 i = 0; i < participants.length; i++) {
            address addr = participants[i];
            uint256 userTickets = userTicketsPerRound[lotteryRound][addr];
            if (userTickets == 0) continue;
            cumulative += userTickets;
            if (winningTicket < cumulative) {
                winner = addr;
                break;
            }
        }

        if (winner == address(0)) {
            for (uint256 i = 0; i < participants.length; i++) {
                address a = participants[i];
                userTicketsPerRound[lotteryRound][a] = 0;
                isParticipantInRound[lotteryRound][a] = false;
            }
            delete roundParticipants[lotteryRound];
            lotteryRound += 1;
            lotteryRoundStart = uint64(block.timestamp);
            emit LotteryRoundStarted(lotteryRound, lotteryRoundStart);
            return;
        }

        uint256 bal = usdc.balanceOf(address(this));
        if (bal < pool) return;

        lotteryPool = 0;
        lastLotteryWinner = winner;

        usdc.safeTransfer(winner, pool);

        emit LotteryWinner(lotteryRound, winner, pool, totalTickets);

        for (uint256 i = 0; i < participants.length; i++) {
            address a = participants[i];
            userTicketsPerRound[lotteryRound][a] = 0;
            isParticipantInRound[lotteryRound][a] = false;
        }
        delete roundParticipants[lotteryRound];

        lotteryRound += 1;
        lotteryRoundStart = uint64(block.timestamp);
        emit LotteryRoundStarted(lotteryRound, lotteryRoundStart);
    }

    function buyBond(uint8 planId,uint256 amountUsdc,address _referrer)
        public
        nonReentrant
        returns (uint256 tokenId)
    {
        _maybeDrawLottery();
        require(planId < plans.length, "PLAN");
        require(amountUsdc > 0, "ZERO");

        usdc.safeTransferFrom(msg.sender, address(this), amountUsdc);

        address finalRef = _referrer;
        if (finalRef == address(0) || finalRef == msg.sender) {
            finalRef = marketing1;
        }

        _setReferrer(msg.sender, finalRef);

        uint256 baseAmount = _handleMarketing(amountUsdc);

        Plan memory p = plans[planId];
        require(p.active, "DISABLED");

        uint256 payout = amountUsdc + (amountUsdc * p.returnBps) / 10000;

        tokenId = totalSupply() + 1;
        _safeMint(msg.sender, tokenId);

        uint64 start = uint64(block.timestamp);
        uint64 end = start + p.lockTime;

        bonds[tokenId] = Bond({
            principal: amountUsdc,
            payout: payout,
            startTime: start,
            endTime: end,
            planId: planId,
            claimed: false
        });

        _updateVolumesOnNewBond(msg.sender, amountUsdc);
        _distributeReferralRewards(msg.sender, amountUsdc);

        uint256 allocatableAmount = _handleLotteryOnBondPurchase(msg.sender, amountUsdc, baseAmount);

        emit BondPurchased(msg.sender, tokenId, planId, amountUsdc, payout, end, referrerOf[msg.sender]);

        if (vault != address(0) && _vaultAllocBps > 0 && allocatableAmount > 0) {
            uint256 toVault = (allocatableAmount * _vaultAllocBps) / 10000;
            if (toVault > 0) {
                usdc.safeTransfer(vault, toVault);
            }
        }
    }

    function buyBondWithName(uint8 planId,uint256 amountUsdc,string calldata refName)
        external
        returns (uint256 tokenId)
    {
        address ref = address(0);
        if (bytes(refName).length > 0) {
            ref = referralNameOwner[keccak256(bytes(refName))];
        }
        tokenId = buyBond(planId, amountUsdc, ref);
    }

    function _isApprovedOrOwnerBF(address spender, uint256 tokenId) internal view returns (bool) {
        address owner = ownerOf(tokenId);
        return (spender == owner || getApproved(tokenId) == spender || isApprovedForAll(owner, spender));
    }

    function claimBond(uint256 tokenId) external nonReentrant {
        _maybeDrawLottery();
        require(_isApprovedOrOwnerBF(msg.sender, tokenId), "NOT_OWNER");
        Bond storage b = bonds[tokenId];
        require(!b.claimed, "CLAIMED");
        require(block.timestamp >= b.endTime, "NOT_MATURED");

        b.claimed = true;

        _updateVolumesOnBondClose(ownerOf(tokenId), b.principal);

        uint256 payout = b.payout;
        uint256 bal = usdc.balanceOf(address(this));

        if (bal < payout && vault != address(0)) {
            IPositionVault(vault).provideLiquidity(payout - bal);
            bal = usdc.balanceOf(address(this));
        }

        require(bal >= payout, "NO_LIQ");

        usdc.safeTransfer(msg.sender, payout);
        emit BondClaimed(msg.sender, tokenId, payout);
    }

    function _getDirectBps(address user) internal view returns (uint16) {
        uint256 vr = volumeNetwork[user];

        if (vr >= 500_000e6) return 350;
        if (vr >= 150_000e6) return 300;
        if (vr >= 50_000e6) return 250;
        if (vr >= 10_000e6) return 200;
        if (vr >= 2_000e6) return 150;
        return 100;
    }

    function _distributeReferralRewards(address buyer,uint256 amount) internal {
        address direct = referrerOf[buyer];
        if (direct == address(0)) return;

        uint16 directBps = _getDirectBps(direct);
        uint256 directReward = (amount * directBps) / 10000;

        if (directReward > 0) {
            referralRewards[direct] += directReward;
            emit ReferralRewardAccrued(direct, directReward);
        }

        uint256 poolIndirect = directReward / 2;
        if (poolIndirect == 0) return;

        address[] memory anc = _getLineage(buyer, 20);
        if (anc.length <= 1) return;

        uint256 indirectCount = anc.length - 1;
        uint256 rewardEach = poolIndirect / indirectCount;
        if (rewardEach == 0) return;

        for (uint256 i = 1; i < anc.length; i++) {
            referralRewards[anc[i]] += rewardEach;
            emit ReferralRewardAccrued(anc[i], rewardEach);
        }
    }

    function _getLineage(address user,uint256 maxDepth) internal view returns (address[] memory) {
        address current = referrerOf[user];
        address[] memory temp = new address[](maxDepth);
        uint256 count;

        while (current != address(0) && count < maxDepth) {
            temp[count] = current;
            current = referrerOf[current];
            count++;
        }

        address[] memory out = new address[](count);
        for (uint256 i = 0; i < count; i++) out[i] = temp[i];
        return out;
    }

    function claimReferralRewards() external nonReentrant {
        _maybeDrawLottery();
        uint256 amt = referralRewards[msg.sender];
        require(amt > 0, "NO_REWARDS");

        uint256 bal = usdc.balanceOf(address(this));
        if (bal < amt && vault != address(0)) {
            IPositionVault(vault).provideLiquidity(amt - bal);
            bal = usdc.balanceOf(address(this));
        }

        require(bal >= amt, "NO_LIQ");
        referralRewards[msg.sender] = 0;

        usdc.safeTransfer(msg.sender, amt);
        emit ReferralRewardClaimed(msg.sender, amt);
    }

    function _updateVolumesOnNewBond(address user,uint256 amount) internal {
        volumePersonal[user] += amount;
        totalPrincipalActive += amount;

        address[] memory anc = _getLineage(user, 100);
        for (uint256 i = 0; i < anc.length; i++) {
            volumeNetwork[anc[i]] += amount;
        }
    }

    function _updateVolumesOnBondClose(address user,uint256 amount) internal {
        volumePersonal[user] -= amount;
        totalPrincipalActive -= amount;

        address[] memory anc = _getLineage(user, 100);
        for (uint256 i = 0; i < anc.length; i++) {
            address current = anc[i];
            uint256 vr = volumeNetwork[current];
            volumeNetwork[current] = vr >= amount ? vr - amount : 0;
        }
    }

    function tvl() external view override returns (uint256) {
        return totalPrincipalActive;
    }

    function vaultAllocBps() external view override returns (uint16) {
        return _vaultAllocBps;
    }

    function fundInflowFromVault(uint256 amount) external override {
        require(msg.sender == vault, "NOT_VAULT");
        emit InflowFromVault(amount);
    }

    function getUserRankBps(address user) external view returns (uint16) {
        return _getDirectBps(user);
    }

    function getUserRankName(address user) external view returns (string memory) {
        uint16 bps = _getDirectBps(user);
        if (bps == 350) return "Legendary";
        if (bps == 300) return "Royal";
        if (bps == 250) return "DiamondElite";
        if (bps == 200) return "Diamond";
        if (bps == 150) return "Gold";
        if (bps == 100) return "Silver";
        return "Unknown";
    }

    function getBond(uint256 tokenId) external view returns (Bond memory) {
        return bonds[tokenId];
    }

    function getUserBonds(address user) external view returns (uint256[] memory) {
        uint256 balance = balanceOf(user);
        uint256[] memory ids = new uint256[](balance);
        for (uint256 i; i < balance; i++) {
            ids[i] = tokenOfOwnerByIndex(user, i);
        }
        return ids;
    }

    function getUserInfo(address user)
        external
        view
        returns (uint256 vp,uint256 vr,uint256 rewards,address referrer,uint16 rankBps,string memory rankName)
    {
        vp = volumePersonal[user];
        vr = volumeNetwork[user];
        rewards = referralRewards[user];
        referrer = referrerOf[user];
        rankBps = _getDirectBps(user);

        if (rankBps == 350) rankName = "Legendary";
        else if (rankBps == 300) rankName = "Royal";
        else if (rankBps == 250) rankName = "DiamondElite";
        else if (rankBps == 200) rankName = "Diamond";
        else if (rankBps == 150) rankName = "Gold";
        else if (rankBps == 100) rankName = "Silver";
        else rankName = "Unknown";
    }

    function getReferralData(address user)
        external
        view
        returns (address referrer,uint256 vp,uint256 vr,uint256 rewards,uint16 rankBps)
    {
        referrer = referrerOf[user];
        vp = volumePersonal[user];
        vr = volumeNetwork[user];
        rewards = referralRewards[user];
        rankBps = _getDirectBps(user);
    }

    function getDirectReferrals(address user) external view returns (address[] memory) {
        return directReferrals[user];
    }

    function getIndirectReferrals(address user) external view returns (address[] memory) {
        address[] memory temp = new address[](MAX_INDIRECT_REFERRALS);
        address[] memory queue = new address[](MAX_INDIRECT_REFERRALS);
        uint256 head;
        uint256 tail;
        uint256 count;

        address[] storage direct = directReferrals[user];
        for (uint256 i = 0; i < direct.length && tail < MAX_INDIRECT_REFERRALS; i++) {
            queue[tail] = direct[i];
            tail++;
        }

        while (head < tail && count < MAX_INDIRECT_REFERRALS) {
            address current = queue[head];
            head++;

            address[] storage children = directReferrals[current];
            for (uint256 j = 0; j < children.length && tail < MAX_INDIRECT_REFERRALS; j++) {
                address child = children[j];
                temp[count] = child;
                count++;
                queue[tail] = child;
                tail++;
                if (count == MAX_INDIRECT_REFERRALS) {
                    break;
                }
            }
        }

        address[] memory out = new address[](count);
        for (uint256 k = 0; k < count; k++) {
            out[k] = temp[k];
        }
        return out;
    }

    function getGlobalStats()
        external
        view
        returns (uint256 tvlTotal,uint256 bondsSupply,uint256 usdcBalance)
    {
        tvlTotal = totalPrincipalActive;
        bondsSupply = totalSupply();
        usdcBalance = usdc.balanceOf(address(this));
    }

    function getPlans()
        external
        view
        returns (Plan memory p0,Plan memory p1,Plan memory p2,Plan memory p3)
    {
        p0 = plans[0];
        p1 = plans[1];
        p2 = plans[2];
        p3 = plans[3];
    }

    function getVaultConfig() external view returns (address vaultAddr,uint16 allocBps) {
        return (vault, _vaultAllocBps);
    }

    function getMarketingConfig()
        external
        view
        returns (
            address m1,address m2,address m3,address m4,
            uint16 bps1,uint16 bps2,uint16 bps3,uint16 bps4
        )
    {
        m1 = marketing1;
        m2 = marketing2;
        m3 = marketing3;
        m4 = marketing4;
        bps1 = MARKETING1_BPS;
        bps2 = MARKETING2_BPS;
        bps3 = MARKETING3_BPS;
        bps4 = MARKETING4_BPS;
    }

    function getUserTicketsForRound(address user, uint256 round)
        external
        view
        returns (uint256)
    {
        return userTicketsPerRound[round][user];
    }

    function getLastWinnerInfo()
        external
        view
        returns (address winner, string memory name)
    {
        winner = lastLotteryWinner;
        name = referralNameOf[winner];
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override
        returns (string memory)
    {
        require(_ownerOf(tokenId) != address(0), "Nonexistent token");

        Bond memory b = bonds[tokenId];
        uint8 planId = b.planId;
        string memory planUri = _planURIs[planId];

        if (bytes(planUri).length > 0) {
            return planUri;
        }

        string memory base = _baseURI();
        if (bytes(base).length == 0) {
            return "";
        }

        return string(abi.encodePacked(base, tokenId.toString(), ".json"));
    }
}
