/**
 * RecommitRecreateBranchController
 *
 * Apex controller for the recommitRecreateBranch LWC bulk list action.
 *
 * Root cause of the original issue:
 *   The commit.js script (Copado Source Format Pipeline) reads process.env.recreateIfExists
 *   to decide whether to delete + re-create the feature branch before committing.
 *   Previous implementations were NOT passing this flag correctly in the DataJson payload,
 *   so the branch was never recreated.
 *
 * Fix:
 *   This controller creates a copado__JobExecution__c record whose copado__DataJson__c
 *   contains recreateIfExists = "true" (string, as commit.js uses == comparison).
 *   Copado's function runner injects all DataJson keys into process.env before executing
 *   commit.js, so the branch delete + recreate path is triggered correctly.
 *
 * Key excerpt from commit.js that this enables:
 *   if (recreateIfExists == 'true') {
 *       git branch -D "${featureBranch}" || true
 *       copado-git-get -g "git push origin --delete ${featureBranch}" || true
 *   }
 */
public with sharing class RecommitRecreateBranchController {

    // ─── Result wrapper returned to the LWC ──────────────────────────────────

    public class CommitResult {
        @AuraEnabled public String userStoryId;
        @AuraEnabled public String userStoryName;
        @AuraEnabled public String status;
        @AuraEnabled public String message;
    }

    // ─── Main entry point (called from LWC) ──────────────────────────────────

    @AuraEnabled
    public static List<CommitResult> triggerRecommitBulk(
        List<String> userStoryIds,
        String       baseBranchOverride,
        Boolean      dryRun
    ) {
        if (userStoryIds == null || userStoryIds.isEmpty()) {
            throw new AuraHandledException('No User Story IDs provided.');
        }

        // ── 1. Query User Stories (single SOQL) ──────────────────────────────
        Map<Id, copado__User_Story__c> storyMap = new Map<Id, copado__User_Story__c>([
            SELECT Id, Name, copado__Base_Branch__c
            FROM   copado__User_Story__c
            WHERE  Id IN :userStoryIds
            WITH   SECURITY_ENFORCED
        ]);

        List<CommitResult>            results      = new List<CommitResult>();
        List<copado__JobExecution__c> jobsToInsert = new List<copado__JobExecution__c>();
        List<Integer>                 jobToResult  = new List<Integer>();

        for (String usId : userStoryIds) {
            CommitResult res = new CommitResult();
            res.userStoryId  = usId;

            copado__User_Story__c story = storyMap.get(usId);
            if (story == null) {
                res.status  = 'Error';
                res.message = 'User Story not found or access denied: ' + usId;
                results.add(res);
                continue;
            }

            res.userStoryName = story.Name;

            // Copado feature branch convention: feature/<US-Name>
            String featureBranch = 'feature/' + story.Name;

            // Base branch priority: override → US field → 'main'
            String baseBranch = String.isNotBlank(baseBranchOverride)
                ? baseBranchOverride
                : (String.isNotBlank(story.copado__Base_Branch__c)
                    ? story.copado__Base_Branch__c
                    : 'main');

            if (dryRun == true) {
                res.status  = 'Dry Run';
                res.message = 'Would recreate branch [' + featureBranch
                            + '] from base [' + baseBranch + '] with recreateIfExists=true';
                results.add(res);
                continue;
            }

            // ── 2. Build the DataJson that commit.js reads via process.env ───
            //
            //  CRITICAL: recreateIfExists must be the string "true" (not Boolean),
            //  because commit.js checks:  if (recreateIfExists == 'true')
            //
            Map<String, Object> dataMap = new Map<String, Object>{
                'recreateIfExists' => 'true',
                'featureBranch'    => featureBranch,
                'baseBranch'       => baseBranch,
                'userStoryId'      => (String) story.Id
            };

            copado__JobExecution__c job = new copado__JobExecution__c(
                copado__DataJson__c = JSON.serialize(dataMap),
                copado__Status__c   = 'Not Started'
            );

            jobsToInsert.add(job);
            jobToResult.add(results.size());
            results.add(res); // placeholder — updated after insert
        }

        // ── 3. Bulk insert all job executions ─────────────────────────────────
        if (!jobsToInsert.isEmpty()) {
            List<Database.SaveResult> saveResults = Database.insert(jobsToInsert, false);
            for (Integer i = 0; i < saveResults.size(); i++) {
                Database.SaveResult     sr  = saveResults[i];
                CommitResult            res = results[jobToResult[i]];
                copado__JobExecution__c job = jobsToInsert[i];

                if (sr.isSuccess()) {
                    res.status  = 'Submitted';
                    res.message = 'Job Execution ' + sr.getId()
                                + ' created with recreateIfExists=true for branch ['
                                + (String)((Map<String,Object>)
                                    JSON.deserializeUntyped(job.copado__DataJson__c))
                                    .get('featureBranch')
                                + ']';
                } else {
                    res.status  = 'Error';
                    res.message = sr.getErrors()[0].getMessage();
                }
            }
        }

        return results;
    }
}