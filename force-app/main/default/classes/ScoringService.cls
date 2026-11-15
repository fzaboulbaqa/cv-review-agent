/**
 * Scores the unscored applicants of a job (0 to 100).
 *
 * Criteria and weights:
 *  - Must-have skills matched:    60
 *  - Nice-to-have skills matched: 20
 *  - Years of experience:         20 (full points at or above the job minimum, proportional below)
 * A criterion that does not apply to the job (no must-have skills, no nice-to-have skills,
 * no minimum years) is left out and the score is computed on the remaining weights.
 *
 * Applicants that already have a score are skipped: a score is set once (see the
 * Score_Locked validation rule on Job_Applicant__c).
 * Reasoning__c is not written here: the AI writes it later from the Breakdown.
 */
public with sharing class ScoringService {
    public static final Decimal MUST_HAVE_WEIGHT = 60;
    public static final Decimal NICE_TO_HAVE_WEIGHT = 20;
    public static final Decimal EXPERIENCE_WEIGHT = 20;

    private static final String MUST_HAVE = 'Must Have';
    private static final String LOG_TAG = 'Scoring';

    public class ScoringException extends Exception {
    }

    /** What the score is made of, so the reasoning can explain it. */
    public class Breakdown {
        public Id jobApplicantId;
        public Id jobId;
        public Id candidateId;
        public Integer score;
        public List<String> matchedMustHave = new List<String>();
        public List<String> missingMustHave = new List<String>();
        public List<String> matchedNiceToHave = new List<String>();
        public List<String> missingNiceToHave = new List<String>();
        public Decimal candidateYears;
        public Decimal requiredYears;
    }

    public class Request {
        @InvocableVariable(required=true label='Job ID')
        public Id jobId;
    }

    public class Result {
        @InvocableVariable(label='Scored Applicants')
        public Integer scoredCount = 0;
    }

    @InvocableMethod(
        label='Score Job Applicants'
        description='Scores the applicants of the job that have no score yet'
        category='CV Review'
    )
    public static List<Result> scoreJobs(List<Request> requests) {
        Set<Id> jobIds = new Set<Id>();
        for (Request request : requests) {
            jobIds.add(request.jobId);
        }

        Map<Id, Result> resultByJobId = new Map<Id, Result>();
        for (Id jobId : jobIds) {
            resultByJobId.put(jobId, new Result());
        }
        for (Breakdown breakdown : scoreApplicants(jobIds)) {
            resultByJobId.get(breakdown.jobId).scoredCount++;
        }

        List<Result> results = new List<Result>();
        for (Request request : requests) {
            results.add(resultByJobId.get(request.jobId));
        }
        return results;
    }

    /**
     * Scores and saves every unscored applicant of the given jobs.
     * Returns one Breakdown per scored applicant.
     */
    public static List<Breakdown> scoreApplicants(Set<Id> jobIds) {
        try {
            List<Job_Applicant__c> applicants = [
                SELECT Id, Job__c, Candidate__c, Candidate__r.Years_Experience__c, Job__r.Min_Years_Experience__c
                FROM Job_Applicant__c
                WHERE Job__c IN :jobIds AND Score__c = NULL
                WITH USER_MODE
            ];
            if (applicants.isEmpty()) {
                return new List<Breakdown>();
            }

            Set<Id> candidateIds = new Set<Id>();
            for (Job_Applicant__c applicant : applicants) {
                candidateIds.add(applicant.Candidate__c);
            }
            Map<Id, List<Job_Skill__c>> jobSkillsByJobId = getJobSkills(jobIds);
            Map<Id, Set<Id>> skillIdsByCandidateId = getCandidateSkillIds(candidateIds);

            List<Breakdown> breakdowns = new List<Breakdown>();
            // Only Id and Score: user mode checks edit access on every field set on the record.
            List<Job_Applicant__c> updates = new List<Job_Applicant__c>();
            for (Job_Applicant__c applicant : applicants) {
                Breakdown breakdown = calculate(
                    jobSkillsByJobId.get(applicant.Job__c),
                    skillIdsByCandidateId.get(applicant.Candidate__c),
                    applicant.Candidate__r.Years_Experience__c,
                    applicant.Job__r.Min_Years_Experience__c
                );
                breakdown.jobApplicantId = applicant.Id;
                breakdown.jobId = applicant.Job__c;
                breakdown.candidateId = applicant.Candidate__c;
                updates.add(new Job_Applicant__c(Id = applicant.Id, Score__c = breakdown.score));
                breakdowns.add(breakdown);
            }

            update as user updates;
            Logger.info('Scored ' + applicants.size() + ' applicant(s) for job(s) ' + jobIds).addTag(LOG_TAG);
            Logger.saveLog();
            return breakdowns;
        } catch (Exception ex) {
            Logger.error('Scoring failed for job(s) ' + jobIds).setExceptionDetails(ex).addTag(LOG_TAG);
            Logger.saveLog();
            throw new ScoringException('Scoring failed: ' + ex.getMessage(), ex);
        }
    }

    /** Pure scoring logic: no queries, no DML. */
    @TestVisible
    private static Breakdown calculate(
        List<Job_Skill__c> jobSkills,
        Set<Id> candidateSkillIds,
        Decimal candidateYears,
        Decimal requiredYears
    ) {
        Breakdown breakdown = new Breakdown();
        breakdown.candidateYears = candidateYears;
        breakdown.requiredYears = requiredYears;
        jobSkills = jobSkills == null ? new List<Job_Skill__c>() : jobSkills;
        candidateSkillIds = candidateSkillIds == null ? new Set<Id>() : candidateSkillIds;

        for (Job_Skill__c jobSkill : jobSkills) {
            Boolean matched = candidateSkillIds.contains(jobSkill.Skill__c);
            if (jobSkill.Importance__c == MUST_HAVE) {
                (matched ? breakdown.matchedMustHave : breakdown.missingMustHave).add(jobSkill.Skill__r.Name);
            } else {
                (matched ? breakdown.matchedNiceToHave : breakdown.missingNiceToHave).add(jobSkill.Skill__r.Name);
            }
        }

        Decimal earned = 0;
        Decimal possible = 0;

        Integer mustHaveCount = breakdown.matchedMustHave.size() + breakdown.missingMustHave.size();
        if (mustHaveCount > 0) {
            earned += MUST_HAVE_WEIGHT * breakdown.matchedMustHave.size() / mustHaveCount;
            possible += MUST_HAVE_WEIGHT;
        }

        Integer niceToHaveCount = breakdown.matchedNiceToHave.size() + breakdown.missingNiceToHave.size();
        if (niceToHaveCount > 0) {
            earned += NICE_TO_HAVE_WEIGHT * breakdown.matchedNiceToHave.size() / niceToHaveCount;
            possible += NICE_TO_HAVE_WEIGHT;
        }

        if (requiredYears != null && requiredYears > 0) {
            // Unknown years earn nothing: the AI reasoning should flag it as a gap to check.
            Decimal years = candidateYears == null ? 0 : candidateYears;
            earned += EXPERIENCE_WEIGHT * Math.min(years / requiredYears, 1);
            possible += EXPERIENCE_WEIGHT;
        }

        // No criteria defined on the job: nothing to measure against.
        breakdown.score = possible == 0 ? 0 : (earned / possible * 100).round(System.RoundingMode.HALF_UP).intValue();
        return breakdown;
    }

    private static Map<Id, List<Job_Skill__c>> getJobSkills(Set<Id> jobIds) {
        Map<Id, List<Job_Skill__c>> jobSkillsByJobId = new Map<Id, List<Job_Skill__c>>();
        for (Job_Skill__c jobSkill : [
            SELECT Job__c, Skill__c, Skill__r.Name, Importance__c
            FROM Job_Skill__c
            WHERE Job__c IN :jobIds
            WITH USER_MODE
        ]) {
            if (!jobSkillsByJobId.containsKey(jobSkill.Job__c)) {
                jobSkillsByJobId.put(jobSkill.Job__c, new List<Job_Skill__c>());
            }
            jobSkillsByJobId.get(jobSkill.Job__c).add(jobSkill);
        }
        return jobSkillsByJobId;
    }

    private static Map<Id, Set<Id>> getCandidateSkillIds(Set<Id> candidateIds) {
        Map<Id, Set<Id>> skillIdsByCandidateId = new Map<Id, Set<Id>>();
        for (Candidate_Skill__c candidateSkill : [
            SELECT Candidate__c, Skill__c
            FROM Candidate_Skill__c
            WHERE Candidate__c IN :candidateIds
            WITH USER_MODE
        ]) {
            if (!skillIdsByCandidateId.containsKey(candidateSkill.Candidate__c)) {
                skillIdsByCandidateId.put(candidateSkill.Candidate__c, new Set<Id>());
            }
            skillIdsByCandidateId.get(candidateSkill.Candidate__c).add(candidateSkill.Skill__c);
        }
        return skillIdsByCandidateId;
    }
}
