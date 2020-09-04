pragma solidity 0.4.24;

import "@aragon/templates-shared/contracts/BaseTemplate.sol";
import "@1hive/apps-dandelion-voting/contracts/DandelionVoting.sol";
import "@1hive/apps-token-manager/contracts/HookedTokenManager.sol";
import {IIssuance as Issuance} from "./external/IIssuance.sol";
import {ITollgate as Tollgate} from "./external/ITollgate.sol";
import {IConvictionVoting as ConvictionVoting} from "./external/IConvictionVoting.sol";


contract HoneyPotTemplate is BaseTemplate {

    string constant private ERROR_MISSING_MEMBERS = "MISSING_MEMBERS";
    string constant private ERROR_BAD_VOTE_SETTINGS = "BAD_SETTINGS";
    string constant private ERROR_NO_CACHE = "NO_CACHE";
    string constant private ERROR_NO_TOLLGATE_TOKEN = "NO_TOLLGATE_TOKEN";

    // rinkeby
     bytes32 private constant DANDELION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("gardens-dandelion-voting")));
     bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("disputable-conviction-voting")));
     bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("gardens-token-manager")));
     bytes32 private constant ISSUANCE_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("issuance")));
     bytes32 private constant TOLLGATE_APP_ID = keccak256(abi.encodePacked(apmNamehash("open"), keccak256("tollgate")));

    // xdai
//    bytes32 private constant DANDELION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("dandelion-voting")));
//    bytes32 private constant CONVICTION_VOTING_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("conviction-voting")));
//    bytes32 private constant HOOKED_TOKEN_MANAGER_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("token-manager")));
//    bytes32 private constant ISSUANCE_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("issuance")));
//    bytes32 private constant TOLLGATE_APP_ID = keccak256(abi.encodePacked(apmNamehash("1hive"), keccak256("tollgate")));

    uint256 private constant VAULT_INITIAL_FUNDS = 1000e18;
    bool private constant TOKEN_TRANSFERABLE = true;
    uint8 private constant TOKEN_DECIMALS = uint8(18);
    uint256 private constant TOKEN_MAX_PER_ACCOUNT = uint256(-1);
    address private constant ANY_ENTITY = address(-1);
    uint8 private constant ORACLE_PARAM_ID = 203;
    enum Op { NONE, EQ, NEQ, GT, LT, GTE, LTE, RET, NOT, AND, OR, XOR, IF_ELSE }

    struct DeployedContracts {
        Kernel dao;
        ACL acl;
        DandelionVoting dandelionVoting;
        Vault fundingPoolVault;
        HookedTokenManager hookedTokenManager;
        Issuance issuance;
        MiniMeToken voteToken;
    }

    event Tokens(MiniMeToken stakeAndRequestToken);
    event ConvictionVotingAddress(ConvictionVoting convictionVoting);

    mapping(address => DeployedContracts) internal senderDeployedContracts;

    constructor(DAOFactory _daoFactory, ENS _ens, MiniMeTokenFactory _miniMeFactory, IFIFSResolvingRegistrar _aragonID)
        BaseTemplate(_daoFactory, _ens, _miniMeFactory, _aragonID)
        public
    {
        _ensureAragonIdIsValid(_aragonID);
        _ensureMiniMeFactoryIsValid(_miniMeFactory);
    }

    // New DAO functions //

    /**
    * @dev Create the DAO and initialise the basic apps necessary for gardens
    * @param _voteTokenName The name for the token used by share holders in the organization
    * @param _voteTokenSymbol The symbol for the token used by share holders in the organization
    * @param _holders some text for _holders
    * @param _stakes some text for _stakes
    * @param _votingSettings Array of [supportRequired, minAcceptanceQuorum, voteDuration, voteBufferBlocks, voteExecutionDelayBlocks] to set up the voting app of the organization

    */
    function createDaoTxOne(
        string _voteTokenName,
        string _voteTokenSymbol,
        address[] _holders,
        uint256[] _stakes,
        uint64[5] _votingSettings
    )
        public
    {
        require(_votingSettings.length == 5, ERROR_BAD_VOTE_SETTINGS);

        (Kernel dao, ACL acl) = _createDAO();
        MiniMeToken voteToken = _createToken(_voteTokenName, _voteTokenSymbol, TOKEN_DECIMALS);
        Vault fundingPoolVault = _installVaultApp(dao);
        DandelionVoting dandelionVoting = _installDandelionVotingApp(dao, voteToken, _votingSettings);
        HookedTokenManager hookedTokenManager = _installHookedTokenManagerApp(dao, voteToken, TOKEN_TRANSFERABLE, TOKEN_MAX_PER_ACCOUNT);

        _createPermissionForTemplate(acl, hookedTokenManager, hookedTokenManager.MINT_ROLE());
        for (uint256 i = 0; i < _holders.length; i++) {
              hookedTokenManager.mint(_holders[i], _stakes[i]);
        }
        hookedTokenManager.mint(address(fundingPoolVault), VAULT_INITIAL_FUNDS);
        _removePermissionFromTemplate(acl, hookedTokenManager, hookedTokenManager.MINT_ROLE());

        _createEvmScriptsRegistryPermissions(acl, dandelionVoting, dandelionVoting);
        _createCustomVotingPermissions(acl, dandelionVoting, hookedTokenManager);

        _storeDeployedContractsTxOne(dao, acl, dandelionVoting, fundingPoolVault, hookedTokenManager, voteToken);

        emit Tokens(voteToken);
    }

    /**
    * @dev Add and initialise tollgate, issuance and conviction voting
    * @param _tollgateFeeAmount The tollgate fee amount
    * @param _issuanceRate Percentage of the token's total supply that will be issued per block (expressed as a percentage of 10^18; eg. 10^16 = 1%, 10^18 = 100%)
    * @param _convictionSettings array of conviction settings: decay, max_ratio, weight and min_threshold_stake_percentage
    */
    function createDaoTxTwo(
        uint256 _tollgateFeeAmount,
        uint256 _issuanceRate,
        uint64[4] _convictionSettings
    )
        public
    {
        require(senderDeployedContracts[msg.sender].dao != address(0), ERROR_NO_CACHE);

        (Kernel dao,
        ACL acl,
        DandelionVoting dandelionVoting,
        Vault fundingPoolVault,
        HookedTokenManager hookedTokenManager,
        MiniMeToken voteToken) = _getDeployedContractsTxOne();

        ERC20 feeToken = ERC20(address(voteToken));

        Tollgate tollgate = _installTollgate(senderDeployedContracts[msg.sender].dao, feeToken, _tollgateFeeAmount, address(fundingPoolVault));
        _createTollgatePermissions(acl, tollgate, dandelionVoting);

        Issuance issuance = _installIssuance(senderDeployedContracts[msg.sender].dao, hookedTokenManager);
        _createPermissionForTemplate(acl, issuance, issuance.ADD_POLICY_ROLE());
        issuance.addPolicy(address(fundingPoolVault), _issuanceRate);
        _removePermissionFromTemplate(acl, issuance, issuance.ADD_POLICY_ROLE());
        _createIssuancePermissions(acl, issuance, dandelionVoting);

        ConvictionVoting convictionVoting = _installConvictionVoting(senderDeployedContracts[msg.sender].dao, hookedTokenManager.token(), fundingPoolVault, hookedTokenManager.token(), _convictionSettings);
        _createVaultPermissions(acl, fundingPoolVault, convictionVoting, dandelionVoting);
        _createConvictionVotingPermissions(acl, convictionVoting, dandelionVoting);

        _createPermissionForTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());
        hookedTokenManager.registerHook(convictionVoting);
        hookedTokenManager.registerHook(dandelionVoting);
        _removePermissionFromTemplate(acl, hookedTokenManager, hookedTokenManager.SET_HOOK_ROLE());
        _createHookedTokenManagerPermissions(acl, dandelionVoting, hookedTokenManager, issuance);

//         _validateId(_id);
        _transferRootPermissionsFromTemplateAndFinalizeDAO(dao, msg.sender);
//         _registerID(_id, dao);
        _deleteStoredContracts();
    }


    // App installation/setup functions //

    function _installHookedTokenManagerApp(
        Kernel _dao,
        MiniMeToken _token,
        bool _transferable,
        uint256 _maxAccountTokens
    )
        internal returns (HookedTokenManager)
    {
        HookedTokenManager hookedTokenManager = HookedTokenManager(_installDefaultApp(_dao, HOOKED_TOKEN_MANAGER_APP_ID));
        _token.changeController(hookedTokenManager);
        hookedTokenManager.initialize(_token, _transferable, _maxAccountTokens);
        return hookedTokenManager;
    }

    function _installDandelionVotingApp(Kernel _dao, MiniMeToken _voteToken, uint64[5] _votingSettings)
        internal returns (DandelionVoting)
    {
        DandelionVoting dandelionVoting = DandelionVoting(_installNonDefaultApp(_dao, DANDELION_VOTING_APP_ID));
        dandelionVoting.initialize(_voteToken, _votingSettings[0], _votingSettings[1], _votingSettings[2],
            _votingSettings[3], _votingSettings[4]);
        return dandelionVoting;
    }

    function _installTollgate(Kernel _dao, ERC20 _tollgateFeeToken, uint256 _tollgateFeeAmount, address _tollgateFeeDestination)
        internal returns (Tollgate)
    {
        Tollgate tollgate = Tollgate(_installNonDefaultApp(_dao, TOLLGATE_APP_ID));
        tollgate.initialize(_tollgateFeeToken, _tollgateFeeAmount, _tollgateFeeDestination);
        return tollgate;
    }

    function _installIssuance(Kernel _dao, HookedTokenManager _hookedTokenManager)
      internal returns (Issuance)
    {
        Issuance issuance = Issuance(_installNonDefaultApp(_dao, ISSUANCE_APP_ID));
        issuance.initialize(_hookedTokenManager);
        return issuance;
    }

    function _installConvictionVoting(Kernel _dao, MiniMeToken _stakeToken, Vault _agentOrVault, MiniMeToken _requestToken, uint64[4] _convictionSettings)
        internal returns (ConvictionVoting)
    {
        ConvictionVoting convictionVoting = ConvictionVoting(_installNonDefaultApp(_dao, CONVICTION_VOTING_APP_ID));
        convictionVoting.initialize(_stakeToken, _agentOrVault, _requestToken, _convictionSettings[0], _convictionSettings[1], _convictionSettings[2], _convictionSettings[3]);
        emit ConvictionVotingAddress(convictionVoting);
        return convictionVoting;
    }

    // Permission setting functions //

    function _createCustomVotingPermissions(ACL _acl, DandelionVoting _dandelionVoting, HookedTokenManager _hookedTokenManager)
        internal
    {
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_QUORUM_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_SUPPORT_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_BUFFER_BLOCKS_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _dandelionVoting, _dandelionVoting.MODIFY_EXECUTION_DELAY_ROLE(), _dandelionVoting);
    }

    function _createTollgatePermissions(ACL _acl, Tollgate _tollgate, DandelionVoting _dandelionVoting) internal {
        _acl.createPermission(_dandelionVoting, _tollgate, _tollgate.CHANGE_AMOUNT_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _tollgate, _tollgate.CHANGE_DESTINATION_ROLE(), _dandelionVoting);
        _acl.createPermission(_tollgate, _dandelionVoting, _dandelionVoting.CREATE_VOTES_ROLE(), _dandelionVoting);
    }

    function _createIssuancePermissions(ACL _acl, Issuance _issuance, DandelionVoting _dandelionVoting) internal {
        _acl.createPermission(_dandelionVoting, _issuance, _issuance.ADD_POLICY_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _issuance, _issuance.REMOVE_POLICY_ROLE(), _dandelionVoting);
    }

    function _createConvictionVotingPermissions(ACL _acl, ConvictionVoting _convictionVoting, DandelionVoting _dandelionVoting)
        internal
    {
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CHALLENGE_ROLE(), _dandelionVoting);
        _acl.createPermission(ANY_ENTITY, _convictionVoting, _convictionVoting.CREATE_PROPOSALS_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _convictionVoting, _convictionVoting.CANCEL_PROPOSALS_ROLE(), _dandelionVoting);
        _acl.createPermission(_dandelionVoting, _convictionVoting, _convictionVoting.UPDATE_SETTINGS_ROLE(), _dandelionVoting);
    }

    function _createHookedTokenManagerPermissions(ACL acl, DandelionVoting dandelionVoting,HookedTokenManager hookedTokenManager, Issuance issuance) internal {
        // (, ACL acl,DandelionVoting dandelionVoting,,HookedTokenManager hookedTokenManager) = _getDeployedContractsTxOne();

        acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.MINT_ROLE(), dandelionVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ISSUE_ROLE(), dandelionVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.ASSIGN_ROLE(), dandelionVoting);
        // acl.createPermission(issuance, hookedTokenManager, hookedTokenManager.REVOKE_VESTINGS_ROLE(), dandelionVoting);
        acl.createPermission(dandelionVoting, hookedTokenManager, hookedTokenManager.BURN_ROLE(), dandelionVoting);

    }

    // Temporary Storage functions //

    function _storeDeployedContractsTxOne(Kernel _dao, ACL _acl, DandelionVoting _dandelionVoting, Vault _agentOrVault, HookedTokenManager _hookedTokenManager, MiniMeToken _voteToken )
        internal
    {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        deployedContracts.dao = _dao;
        deployedContracts.acl = _acl;
        deployedContracts.dandelionVoting = _dandelionVoting;
        deployedContracts.fundingPoolVault = _agentOrVault;
        deployedContracts.hookedTokenManager = _hookedTokenManager;
        deployedContracts.voteToken = _voteToken;
    }

    function _getDeployedContractsTxOne() internal returns (Kernel, ACL, DandelionVoting, Vault, HookedTokenManager, MiniMeToken voteToken) {
        DeployedContracts storage deployedContracts = senderDeployedContracts[msg.sender];
        return (
            deployedContracts.dao,
            deployedContracts.acl,
            deployedContracts.dandelionVoting,
            deployedContracts.fundingPoolVault,
            deployedContracts.hookedTokenManager,
            deployedContracts.voteToken
        );
    }


    function _deleteStoredContracts() internal {
        delete senderDeployedContracts[msg.sender];
    }

    // Oracle permissions with params functions //

    function _setOracle(ACL _acl, address _who, address _where, bytes32 _what, address _oracle) private {
        uint256[] memory params = new uint256[](1);
        params[0] = _paramsTo256(ORACLE_PARAM_ID, uint8(Op.EQ), uint240(_oracle));

        _acl.grantPermissionP(_who, _where, _what, params);
    }

    function _paramsTo256(uint8 _id,uint8 _op, uint240 _value) private returns (uint256) {
        return (uint256(_id) << 248) + (uint256(_op) << 240) + _value;
    }
}
