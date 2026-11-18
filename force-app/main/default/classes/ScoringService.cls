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
 * Reasoning__c is not written here: CandidateRecommendationService has the AI write it from
 * the Breakdown.
 */
public with sharing class ScoringService {
  public static final Decimal MUST_HAVE_WEIGHT = 60;
  public static final Decimal NICE_TO_HAVE_WEIGHT = 20;
  public static final Decimal EXPERIENCE_WEIGHT = 20;

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
    /** True when the score was already saved before (it is locked once set). */
    public Boolean alreadyScored = false;
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
        SELECT
          Id,
          Job__c,
          Candidate__c,
          Score__c,
          Candidate__r.Years_Experience__c,
          Job__r.Min_Years_Experience__c
        FROM Job_Applicant__c
        WHERE Job__c IN :jobIds AND Score__c = NULL
        WITH USER_MODE
      ];
      return scoreAndSave(applicants);
    } catch (Exception ex) {
      throw scoringError('job(s) ' + jobIds, ex);
    }
  }

  /**
   * Scores and saves the unscored applications of these candidates only. Used once their card
   * is filled: the other applicants of the same jobs may not have a card yet, and a score is
   * locked once set, so they must not be scored now.
   */
  public static List<Breakdown> scoreCandidates(Set<Id> candidateIds) {
    try {
      List<Job_Applicant__c> applicants = [
        SELECT
          Id,
          Job__c,
          Candidate__c,
          Score__c,
          Candidate__r.Years_Experience__c,
          Job__r.Min_Years_Experience__c
        FROM Job_Applicant__c
        WHERE Candidate__c IN :candidateIds AND Score__c = NULL
        WITH USER_MODE
      ];
      return scoreAndSave(applicants);
    } catch (Exception ex) {
      throw scoringError('candidate(s) ' + candidateIds, ex);
    }
  }

  private static List<Breakdown> scoreAndSave(
    List<Job_Applicant__c> applicants
  ) {
    List<Breakdown> breakdowns = build(applicants);
    saveScores(breakdowns);
    return breakdowns;
  }

  private static ScoringException scoringError(String scope, Exception ex) {
    Logger.error('Scoring failed for ' + scope)
      .setExceptionDetails(ex)
      .addTag(Constants.LOG_TAG_SCORING);
    Logger.saveLog();
    return new ScoringException('Scoring failed: ' + ex.getMessage(), ex);
  }

  /**
   * Breakdowns of the applicants of a job (scored or not), WITHOUT saving anything.
   * Used by the comparison: it calls the AI first, and no DML is allowed before a callout.
   * An applicant that already has a score keeps it (alreadyScored = true); the breakdown then
   * explains it with the candidate's current skills.
   * candidateIds: optional, limits the result to these candidates.
   */
  public static List<Breakdown> explainApplicants(
    Id jobId,
    Set<Id> candidateIds
  ) {
    List<Job_Applicant__c> applicants = new List<Job_Applicant__c>();
    for (Job_Applicant__c applicant : [
      SELECT
        Id,
        Job__c,
        Candidate__c,
        Score__c,
        Candidate__r.Years_Experience__c,
        Job__r.Min_Years_Experience__c
      FROM Job_Applicant__c
      WHERE Job__c = :jobId
      WITH USER_MODE
    ]) {
      Boolean noFilter = candidateIds == null || candidateIds.isEmpty();
      if (noFilter || candidateIds.contains(applicant.Candidate__c)) {
        applicants.add(applicant);
      }
    }
    return build(applicants);
  }

  /** Saves the score of the breakdowns that were not scored yet. */
  public static void saveScores(List<Breakdown> breakdowns) {
    // Only Id and Score: user mode checks edit access on every field set on the record.
    List<Job_Applicant__c> updates = new List<Job_Applicant__c>();
    Set<Id> jobIds = new Set<Id>();
    for (Breakdown breakdown : breakdowns) {
      if (!breakdown.alreadyScored) {
        updates.add(
          new Job_Applicant__c(
            Id = breakdown.jobApplicantId,
            Score__c = breakdown.score
          )
        );
        jobIds.add(breakdown.jobId);
      }
    }
    if (updates.isEmpty()) {
      return;
    }
    update as user updates;
    for (Breakdown breakdown : breakdowns) {
      breakdown.alreadyScored = true;
    }
    String message = 'Scored ' + updates.size() + ' applicant(s)';
    message += ' for job(s) ' + jobIds;
    Logger.info(message).addTag(Constants.LOG_TAG_SCORING);
    Logger.saveLog();
  }

  private static List<Breakdown> build(List<Job_Applicant__c> applicants) {
    List<Breakdown> breakdowns = new List<Breakdown>();
    if (applicants.isEmpty()) {
      return breakdowns;
    }
    Set<Id> jobIds = new Set<Id>();
    Set<Id> candidateIds = new Set<Id>();
    for (Job_Applicant__c applicant : applicants) {
      jobIds.add(applicant.Job__c);
      candidateIds.add(applicant.Candidate__c);
    }
    Map<Id, List<Job_Skill__c>> jobSkillsByJobId = getJobSkills(jobIds);
    Map<Id, Set<Id>> skillIdsByCandidateId = getCandidateSkillIds(candidateIds);

    for (Job_Applicant__c applicant : applicants) {
      List<Job_Skill__c> jobSkills = jobSkillsByJobId.get(applicant.Job__c);
      Set<Id> candidateSkillIds = skillIdsByCandidateId.get(
        applicant.Candidate__c
      );
      Breakdown breakdown = calculate(
        jobSkills,
        candidateSkillIds,
        applicant.Candidate__r.Years_Experience__c,
        applicant.Job__r.Min_Years_Experience__c
      );
      breakdown.jobApplicantId = applicant.Id;
      breakdown.jobId = applicant.Job__c;
      breakdown.candidateId = applicant.Candidate__c;
      if (applicant.Score__c != null) {
        breakdown.score = applicant.Score__c.intValue();
        breakdown.alreadyScored = true;
      }
      breakdowns.add(breakdown);
    }
    return breakdowns;
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
    if (jobSkills == null) {
      jobSkills = new List<Job_Skill__c>();
    }
    if (candidateSkillIds == null) {
      candidateSkillIds = new Set<Id>();
    }
    sortSkills(breakdown, jobSkills, candidateSkillIds);

    Decimal earned = 0;
    Decimal possible = 0;

    Integer mustHaveMatched = breakdown.matchedMustHave.size();
    Integer mustHaveCount = mustHaveMatched + breakdown.missingMustHave.size();
    if (mustHaveCount > 0) {
      earned += MUST_HAVE_WEIGHT * mustHaveMatched / mustHaveCount;
      possible += MUST_HAVE_WEIGHT;
    }

    Integer niceToHaveMatched = breakdown.matchedNiceToHave.size();
    Integer niceToHaveCount =
      niceToHaveMatched + breakdown.missingNiceToHave.size();
    if (niceToHaveCount > 0) {
      earned += NICE_TO_HAVE_WEIGHT * niceToHaveMatched / niceToHaveCount;
      possible += NICE_TO_HAVE_WEIGHT;
    }

    if (requiredYears != null && requiredYears > 0) {
      // Unknown years earn nothing: the AI reasoning should flag it as a gap to check.
      Decimal years = 0;
      if (candidateYears != null) {
        years = candidateYears;
      }
      Decimal experienceRatio = Math.min(years / requiredYears, 1);
      earned += EXPERIENCE_WEIGHT * experienceRatio;
      possible += EXPERIENCE_WEIGHT;
    }

    // No criteria defined on the job: nothing to measure against.
    if (possible == 0) {
      breakdown.score = 0;
      return breakdown;
    }
    Decimal percent = earned / possible * 100;
    breakdown.score = percent.round(System.RoundingMode.HALF_UP).intValue();
    return breakdown;
  }

  /** Puts each job skill in the matched or missing list (must-have or nice-to-have). */
  private static void sortSkills(
    Breakdown breakdown,
    List<Job_Skill__c> jobSkills,
    Set<Id> candidateSkillIds
  ) {
    for (Job_Skill__c jobSkill : jobSkills) {
      String skillName = jobSkill.Skill__r.Name;
      Boolean matched = candidateSkillIds.contains(jobSkill.Skill__c);
      Boolean mustHave =
        jobSkill.Importance__c == Constants.IMPORTANCE_MUST_HAVE;
      if (mustHave && matched) {
        breakdown.matchedMustHave.add(skillName);
      } else if (mustHave) {
        breakdown.missingMustHave.add(skillName);
      } else if (matched) {
        breakdown.matchedNiceToHave.add(skillName);
      } else {
        breakdown.missingNiceToHave.add(skillName);
      }
    }
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
      skillIdsByCandidateId.get(candidateSkill.Candidate__c)
        .add(candidateSkill.Skill__c);
    }
    return skillIdsByCandidateId;
  }
}
