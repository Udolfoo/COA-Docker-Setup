"""Cap the quest menu at the client limit instead of aborting the worldserver.

Background: the CoA Call Boards (game objects 402000/402001) carry 43 quest relations each.
Player::PrepareQuestMenu() fed all of them into the core quest menu, which the client only
supports up to GOSSIP_MAX_MENU_ITEMS (32) entries. The ASSERT in QuestMenu::AddMenuItem()
aborted the whole worldserver as soon as a player (in practice: a playerbot) read a board -
the crash loop in Errors.log/Server.log looked like:

    ASSERTION FAILED
    # Location: /azerothcore/src/server/game/Entities/Creature/GossipDef.cpp:292
    # Function: AddMenuItem
    # Condition: _questMenuItems.size() <= GOSSIP_MAX_MENU_ITEMS

This script is idempotent: it only patches a file whose original pattern is still present and
reports "already patched" otherwise. It is called by coa-update.sh (build fix 3), because that
script resets the core checkout to the upstream revision on every update.

Usage: python3 fix-quest-menu-overflow.py [/opt/azerothcore]
"""

import sys
from pathlib import Path

AC_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/opt/azerothcore")

PLAYER_QUEST = AC_DIR / "src/server/game/Entities/Player/PlayerQuest.cpp"
GOSSIP_DEF = AC_DIR / "src/server/game/Entities/Creature/GossipDef.cpp"

PLAYER_QUEST_MARKER = "addQuestToMenu"
GOSSIP_MARKER = "QuestMenu::AddMenuItem: menu is full"

PLAYER_QUEST_OLD = """    QuestRelationBounds objectQR;
    QuestRelationBounds objectQIR;

    // pets also can have quests
    Creature* creature = ObjectAccessor::GetCreatureOrPetOrVehicle(*this, guid);
    if (creature)
    {
        objectQR  = sObjectMgr->GetCreatureQuestRelationBounds(creature->GetEntry());
        objectQIR = sObjectMgr->GetCreatureQuestInvolvedRelationBounds(creature->GetEntry());
    }
    else
    {
        //we should obtain map pointer from GetMap() in 99% of cases. Special case
        //only for quests which cast teleport spells on player
        Map* _map = IsInWorld() ? GetMap() : sMapMgr->FindMap(GetMapId(), GetInstanceId());
        ASSERT(_map);
        GameObject* pGameObject = _map->GetGameObject(guid);
        if (pGameObject)
        {
            objectQR  = sObjectMgr->GetGOQuestRelationBounds(pGameObject->GetEntry());
            objectQIR = sObjectMgr->GetGOQuestInvolvedRelationBounds(pGameObject->GetEntry());
        }
        else
            return;
    }

    QuestMenu& qm = PlayerTalkClass->GetQuestMenu();
    qm.ClearMenu();

    for (QuestRelations::const_iterator i = objectQIR.first; i != objectQIR.second; ++i)
    {
        uint32 quest_id = i->second;
        QuestStatus status = GetQuestStatus(quest_id);
        if (status == QUEST_STATUS_COMPLETE)
            qm.AddMenuItem(quest_id, 4);
        else if (status == QUEST_STATUS_INCOMPLETE)
            qm.AddMenuItem(quest_id, 4);
        //else if (status == QUEST_STATUS_AVAILABLE)
        //    qm.AddMenuItem(quest_id, 2);
    }

    for (QuestRelations::const_iterator i = objectQR.first; i != objectQR.second; ++i)
    {
        uint32 quest_id = i->second;
        Quest const* quest = sObjectMgr->GetQuestTemplate(quest_id);
        if (!quest)
            continue;

        if (!CanTakeQuest(quest, false))
            continue;

        if (quest->IsAutoComplete() && (!quest->IsRepeatable() || quest->IsDaily() || quest->IsWeekly() || quest->IsMonthly()))
            qm.AddMenuItem(quest_id, 0);
        else if (quest->IsAutoComplete())
            qm.AddMenuItem(quest_id, 4);
        else if (GetQuestStatus(quest_id) == QUEST_STATUS_NONE)
            qm.AddMenuItem(quest_id, 2);
    }
}
"""

PLAYER_QUEST_NEW = """    QuestRelationBounds objectQR;
    QuestRelationBounds objectQIR;
    uint32 sourceEntry = 0;

    // pets also can have quests
    Creature* creature = ObjectAccessor::GetCreatureOrPetOrVehicle(*this, guid);
    if (creature)
    {
        objectQR  = sObjectMgr->GetCreatureQuestRelationBounds(creature->GetEntry());
        objectQIR = sObjectMgr->GetCreatureQuestInvolvedRelationBounds(creature->GetEntry());
        sourceEntry = creature->GetEntry();
    }
    else
    {
        //we should obtain map pointer from GetMap() in 99% of cases. Special case
        //only for quests which cast teleport spells on player
        Map* _map = IsInWorld() ? GetMap() : sMapMgr->FindMap(GetMapId(), GetInstanceId());
        ASSERT(_map);
        GameObject* pGameObject = _map->GetGameObject(guid);
        if (pGameObject)
        {
            objectQR  = sObjectMgr->GetGOQuestRelationBounds(pGameObject->GetEntry());
            objectQIR = sObjectMgr->GetGOQuestInvolvedRelationBounds(pGameObject->GetEntry());
            sourceEntry = pGameObject->GetEntry();
        }
        else
            return;
    }

    QuestMenu& qm = PlayerTalkClass->GetQuestMenu();
    qm.ClearMenu();

    // The client only displays GOSSIP_MAX_MENU_ITEMS quest entries. One quest giver can have more quest
    // relations than that (the Call Boards offer 43 quests), so the menu is capped here instead of
    // aborting the whole worldserver on the first quest that does not fit.
    bool menuLimitLogged = false;
    auto addQuestToMenu = [&](uint32 questId, uint8 icon)
    {
        if (qm.GetMenuItemCount() >= GOSSIP_MAX_MENU_ITEMS)
        {
            if (!menuLimitLogged)
            {
                menuLimitLogged = true;
                LOG_ERROR("entities.player.quest", "Player::PrepareQuestMenu: quest menu of source entry {} (guid {}) is full ({} entries); quest {} and the following quests are not offered to {}.",
                    sourceEntry, guid.ToString(), GOSSIP_MAX_MENU_ITEMS, questId, GetName());
            }
            return;
        }

        qm.AddMenuItem(questId, icon);
    };

    for (QuestRelations::const_iterator i = objectQIR.first; i != objectQIR.second; ++i)
    {
        uint32 quest_id = i->second;
        QuestStatus status = GetQuestStatus(quest_id);
        if (status == QUEST_STATUS_COMPLETE)
            addQuestToMenu(quest_id, 4);
        else if (status == QUEST_STATUS_INCOMPLETE)
            addQuestToMenu(quest_id, 4);
        //else if (status == QUEST_STATUS_AVAILABLE)
        //    addQuestToMenu(quest_id, 2);
    }

    for (QuestRelations::const_iterator i = objectQR.first; i != objectQR.second; ++i)
    {
        uint32 quest_id = i->second;
        Quest const* quest = sObjectMgr->GetQuestTemplate(quest_id);
        if (!quest)
            continue;

        if (!CanTakeQuest(quest, false))
            continue;

        if (quest->IsAutoComplete() && (!quest->IsRepeatable() || quest->IsDaily() || quest->IsWeekly() || quest->IsMonthly()))
            addQuestToMenu(quest_id, 0);
        else if (quest->IsAutoComplete())
            addQuestToMenu(quest_id, 4);
        else if (GetQuestStatus(quest_id) == QUEST_STATUS_NONE)
            addQuestToMenu(quest_id, 2);
    }
}
"""

GOSSIP_OLD = "    ASSERT(_questMenuItems.size() <= GOSSIP_MAX_MENU_ITEMS);\n"

GOSSIP_NEW = """    // The client cannot display more entries than GOSSIP_MAX_MENU_ITEMS; content with more quest
    // relations on one object (Call Boards: 43) used to abort the whole worldserver right here.
    if (_questMenuItems.size() >= GOSSIP_MAX_MENU_ITEMS)
    {
        LOG_ERROR("entities.player.quest", "QuestMenu::AddMenuItem: menu is full ({} entries), quest {} is not added.", GOSSIP_MAX_MENU_ITEMS, QuestId);
        return;
    }
"""


def patch(path, old, new, marker, label):
    if not path.is_file():
        raise SystemExit(f"FAILED: {path} not found")
    text = path.read_text(encoding="utf-8")
    if marker in text:
        print(f"{label}: already patched")
        return
    if text.count(old) != 1:
        raise SystemExit(f"FAILED: {label}: expected exactly one original pattern in {path}, found {text.count(old)}")
    path.write_text(text.replace(old, new), encoding="utf-8")
    print(f"{label}: patched {path}")


patch(PLAYER_QUEST, PLAYER_QUEST_OLD, PLAYER_QUEST_NEW, PLAYER_QUEST_MARKER, "quest menu cap (PrepareQuestMenu)")
patch(GOSSIP_DEF, GOSSIP_OLD, GOSSIP_NEW, GOSSIP_MARKER, "quest menu cap (QuestMenu::AddMenuItem)")

