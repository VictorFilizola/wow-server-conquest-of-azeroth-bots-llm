/*
 * mod-llm-chatter - per-character online flag on logout
 */

#include "LLMChatterOnlineState.h"

#include "DatabaseEnv.h"
#include "LLMChatterConfig.h"
#include "Player.h"
#include "ScriptMgr.h"

// On logout the core marks every character of the account offline.
// That fits one character per account, but playerbots log in under
// shared accounts: an alt bot uses its owner's account and random bots
// share theirs. One bot logging out would flag the real player, or the
// other bots of the account, offline while they are still in the
// world, and the bridge would treat the realm as empty.
class LLMChatterOnlineStateDatabaseScript : public DatabaseScript
{
public:
    LLMChatterOnlineStateDatabaseScript()
        : DatabaseScript("LLMChatterOnlineStateDatabaseScript")
    {
    }

    void OnDatabaseSelectIndexLogout(
        Player* player, uint32& statementIndex, uint32& statementParam) override
    {
        if (!sLLMChatterConfig->IsEnabled() || !player)
            return;

        statementIndex = CHAR_UPD_CHAR_OFFLINE;
        statementParam = player->GetGUID().GetCounter();
    }
};

void AddLLMChatterOnlineStateScripts()
{
    new LLMChatterOnlineStateDatabaseScript();
}
