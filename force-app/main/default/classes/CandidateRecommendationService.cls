/**
 * Compares the applicants of a job and recommends one or more of them.
 *
 * Who decides what:
 *  - The ranking and the scores come from ScoringService (fixed rules, same data = same score).
 *    The AI never changes them.
 *  - The "Score breakdown" part of the reasoning is written by Apex from the Breakdown, so it
 *    can't contradict the number.
 *  - The AI (template CV_Recommend) writes the recommendation: strengths, concerns, trade-offs
 *    between the top candidates, and the gaps to check in interview, from the breakdown and the
 *    CV text. When no applicant is a strong match it names the best available one and the risks.
 *  - If the AI fails, the recruiter still gets the ranking and the breakdown (no AI text).
 *
 * Saved: the score of applicants not scored yet, and Job_Applicant__c.Reasoning__c when it is
 * still empty (a reasoning is written once, like the score, so a bookmark keeps what the
 * recruiter saw). Every recommendation is logged with the tag "Agent Decision" (audit).
 */
public with sharing class CandidateRecommendationService {
  @TestVisible
  private static final Integer MAX_FOR_AI = 10;
  @TestVisible
  private static final Integer MAX_CV_CHARS = 6000;

  public class Ranked {
    public Integer rank;
    public Id applicantId;
    public Id candidateId;
    public String candidateName;
    public Integer score;
    public String matchLevel;
    public String breakdown;
  }

  public class Recommendation {
    public String jobName;
    public List<Ranked> ranking = new List<Ranked>();
    /** AI text, or the reason it's missing. */
    public String recommendation;
    public Boolean aiAvailable = false;
    public Boolean hasStrongMatch = false;
    public Id topApplicantId;
  }

  public class RecommendationException extends Exception {
  }

  public static Recommendation recommend(Id jobId, Set<Id> candidateIds) {
    List<Job__c> jobs = [
      SELECT
        Id,
        Name,
        Description__c,
        Min_Years_Experience__c,
        (
          SELECT Skill__r.Name, Importance__c
          FROM Job_Skills__r
          ORDER BY Skill__r.Name
        )
      FROM Job__c
      WHERE Id = :jobId
      WITH USER_MODE
    ];
    if (jobs.isEmpty()) {
      throw new RecommendationException('Job not found or not accessible.');
    }
    Job__c job = jobs[0];

    List<ScoringService.Breakdown> breakdowns = ScoringService.explainApplicants(
      jobId,
      candidateIds
    );
    if (breakdowns.isEmpty()) {
      throw new RecommendationException(
        'The job "' + job.Name + '" has no matching applicants to compare.'
      );
    }
    Map<Id, Candidate__c> candidates = candidates(breakdowns);
    breakdowns.sort(new ByScore(candidates));

    Recommendation result = new Recommendation();
    result.jobName = job.Name;
    Map<Id, ScoringService.Breakdown> breakdownByApplicant = new Map<Id, ScoringService.Breakdown>();
    for (ScoringService.Breakdown breakdown : breakdowns) {
      Ranked ranked = new Ranked();
      ranked.rank = result.ranking.size() + 1;
      ranked.applicantId = breakdown.jobApplicantId;
      ranked.candidateId = breakdown.candidateId;
      ranked.candidateName = candidates.get(breakdown.candidateId).Name;
      ranked.score = breakdown.score;
      ranked.matchLevel = Constants.matchLevel(breakdown.score);
      ranked.breakdown = explain(breakdown);
      result.ranking.add(ranked);
      breakdownByApplicant.put(breakdown.jobApplicantId, breakdown);
    }
    result.topApplicantId = result.ranking[0].applicantId;
    result.hasStrongMatch =
      result.ranking[0].score >= Constants.MATCH_STRONG_SCORE;

    // 1. AI first (no DML before a callout).
    Map<Id, String> aiReasoning = new Map<Id, String>();
    try {
      Map<String, Object> answer = AiPrompt.parseJsonObject(
        AiPrompt.run(
          Constants.TEMPLATE_RECOMMEND,
          new Map<String, Object>{
            'Job' => describeJob(job),
            'Applicants' => describeApplicants(result.ranking, candidates)
          }
        )
      );
      String text = AiPrompt.text(answer, 'recommendation');
      result.recommendation = text == null
        ? null
        : AiPrompt.withoutCourtesy(text);
      result.aiAvailable = result.recommendation != null;
      for (Map<String, Object> item : AiPrompt.objects(answer, 'applicants')) {
        Id applicantId = toId(AiPrompt.text(item, 'applicantId'));
        String reasoning = AiPrompt.text(item, 'reasoning');
        // Only Ids we sent: the AI can't attach a reasoning to another record.
        if (
          applicantId != null &&
          breakdownByApplicant.containsKey(applicantId) &&
          reasoning != null
        ) {
          aiReasoning.put(applicantId, reasoning);
        }
      }
    } catch (Exception ex) {
      Logger.error('AI recommendation failed for job ' + jobId)
        .setExceptionDetails(ex)
        .addTag(Constants.LOG_TAG_AGENT_DECISION);
    }
    if (!result.aiAvailable) {
      result.recommendation =
        'The AI recommendation is not available right now. The ranking below comes from the ' +
        'scoring rules only.';
    }

    // 2. Save scores and missing reasonings.
    ScoringService.saveScores(breakdowns);
    saveReasoning(result.ranking, aiReasoning);

    Logger.info(
        'Agent decision: recommendation for job ' +
          job.Name +
          ' (' +
          jobId +
          '). Ranking: ' +
          rankingLine(result.ranking) +
          '. Strong match: ' +
          result.hasStrongMatch +
          '. AI text: ' +
          result.aiAvailable
      )
      .addTag(Constants.LOG_TAG_AGENT_DECISION);
    Logger.saveLog();
    return result;
  }

  /** The score, criterion by criterion, in plain words (explainability). */
  @TestVisible
  private static String explain(ScoringService.Breakdown breakdown) {
    List<String> lines = new List<String>();
    Integer mustTotal =
      breakdown.matchedMustHave.size() + breakdown.missingMustHave.size();
    if (mustTotal > 0) {
      lines.add(
        skillLine(
          'Must-have skills',
          breakdown.matchedMustHave,
          breakdown.missingMustHave
        )
      );
    }
    Integer niceTotal =
      breakdown.matchedNiceToHave.size() + breakdown.missingNiceToHave.size();
    if (niceTotal > 0) {
      lines.add(
        skillLine(
          'Nice-to-have skills',
          breakdown.matchedNiceToHave,
          breakdown.missingNiceToHave
        )
      );
    }
    if (breakdown.requiredYears != null && breakdown.requiredYears > 0) {
      lines.add(
        'Experience: ' +
          (breakdown.candidateYears == null
            ? 'not stated in the CV (0 points, check in interview)'
            : breakdown.candidateYears + ' years') +
          ' for ' +
          breakdown.requiredYears +
          ' required'
      );
    }
    if (lines.isEmpty()) {
      lines.add(
        'The job has no skills or minimum experience to score against.'
      );
    }
    return String.join(lines, '\n');
  }

  private static Id toId(String value) {
    try {
      return value == null ? null : Id.valueOf(value);
    } catch (Exception ex) {
      return null;
    }
  }

  /** "Must-have skills: 1 of 3 (has Apex; missing LWC, SOQL)" */
  private static String skillLine(
    String label,
    List<String> matched,
    List<String> missing
  ) {
    List<String> parts = new List<String>();
    if (!matched.isEmpty()) {
      parts.add('has ' + String.join(matched, ', '));
    }
    if (!missing.isEmpty()) {
      parts.add('missing ' + String.join(missing, ', '));
    }
    return label +
      ': ' +
      matched.size() +
      ' of ' +
      (matched.size() + missing.size()) +
      ' (' +
      String.join(parts, '; ') +
      ')';
  }

  private static void saveReasoning(
    List<Ranked> ranking,
    Map<Id, String> aiReasoning
  ) {
    Set<Id> applicantIds = new Set<Id>();
    for (Ranked ranked : ranking) {
      applicantIds.add(ranked.applicantId);
    }
    // Long text can't be filtered in SOQL: the empty ones are picked in Apex.
    Map<Id, Job_Applicant__c> applicants = new Map<Id, Job_Applicant__c>();
    for (Job_Applicant__c applicant : [
      SELECT Id, Reasoning__c
      FROM Job_Applicant__c
      WHERE Id IN :applicantIds
      WITH USER_MODE
    ]) {
      if (String.isBlank(applicant.Reasoning__c)) {
        applicants.put(applicant.Id, applicant);
      }
    }
    List<Job_Applicant__c> updates = new List<Job_Applicant__c>();
    for (Ranked ranked : ranking) {
      // Without the AI text, wait for a later comparison: the reasoning is written once.
      if (
        applicants.containsKey(ranked.applicantId) &&
        aiReasoning.containsKey(ranked.applicantId)
      ) {
        updates.add(
          new Job_Applicant__c(
            Id = ranked.applicantId,
            Reasoning__c = ('Score: ' +
              ranked.score +
              ' (' +
              ranked.matchLevel +
              ')\n' +
              'Score breakdown:\n' +
              ranked.breakdown +
              '\n\n' +
              aiReasoning.get(ranked.applicantId))
              .left(Constants.LONG_TEXT_MAX_LENGTH)
          )
        );
      }
    }
    update as user updates;
  }

  private static String describeJob(Job__c job) {
    List<String> must = new List<String>();
    List<String> nice = new List<String>();
    for (Job_Skill__c jobSkill : job.Job_Skills__r) {
      (jobSkill.Importance__c == Constants.IMPORTANCE_MUST_HAVE ? must : nice)
        .add(jobSkill.Skill__r.Name);
    }
    return 'Job: ' +
      job.Name +
      '\n' +
      'Minimum years of experience: ' +
      (job.Min_Years_Experience__c == null
        ? 'none'
        : String.valueOf(job.Min_Years_Experience__c)) +
      '\n' +
      'Must-have skills: ' +
      (must.isEmpty() ? 'none' : String.join(must, ', ')) +
      '\n' +
      'Nice-to-have skills: ' +
      (nice.isEmpty() ? 'none' : String.join(nice, ', ')) +
      '\n' +
      'Description:\n' +
      (job.Description__c == null ? '(none)' : job.Description__c.left(4000));
  }

  private static String describeApplicants(
    List<Ranked> ranking,
    Map<Id, Candidate__c> candidates
  ) {
    List<String> parts = new List<String>();
    for (Ranked ranked : ranking) {
      if (parts.size() == MAX_FOR_AI) {
        break;
      }
      Candidate__c candidate = candidates.get(ranked.candidateId);
      String cvText = String.isBlank(candidate.CV_Text__c)
        ? '(No CV text available.)'
        : candidate.CV_Text__c.left(MAX_CV_CHARS).replace('"""', '\'\'\'');
      parts.add(
        'Rank ' +
          ranked.rank +
          ': ' +
          ranked.candidateName +
          '\n' +
          'applicantId: ' +
          ranked.applicantId +
          '\n' +
          'Score: ' +
          ranked.score +
          ' of 100 (' +
          ranked.matchLevel +
          ')\n' +
          'Score breakdown:\n' +
          ranked.breakdown +
          '\n' +
          'Data issues on the card: ' +
          flagSummary(candidate) +
          '\n' +
          'CV text:\n"""\n' +
          cvText +
          '\n"""'
      );
    }
    return String.join(parts, '\n\n');
  }

  private static String flagSummary(Candidate__c candidate) {
    List<String> items = new List<String>();
    for (Extraction_Flag__c item : candidate.Extraction_Flags__r) {
      items.add(
        item.Type__c + ' ' + item.Field__c + ': ' + item.Detail__c.left(200)
      );
    }
    return items.isEmpty() ? 'none' : String.join(items, ' | ');
  }

  private static String rankingLine(List<Ranked> ranking) {
    List<String> items = new List<String>();
    for (Ranked ranked : ranking) {
      items.add(ranked.rank + '. ' + ranked.candidateName + ' ' + ranked.score);
    }
    return String.join(items, ', ');
  }

  private static Map<Id, Candidate__c> candidates(
    List<ScoringService.Breakdown> breakdowns
  ) {
    Set<Id> candidateIds = new Set<Id>();
    for (ScoringService.Breakdown breakdown : breakdowns) {
      candidateIds.add(breakdown.candidateId);
    }
    return new Map<Id, Candidate__c>(
      [
        SELECT
          Id,
          Name,
          CV_Text__c,
          (
            SELECT Type__c, Field__c, Detail__c
            FROM Extraction_Flags__r
            ORDER BY Type__c
            LIMIT 20
          )
        FROM Candidate__c
        WHERE Id IN :candidateIds
        WITH USER_MODE
      ]
    );
  }

  /** Best score first; ties: more must-have skills, then name. */
  private class ByScore implements Comparator<ScoringService.Breakdown> {
    private final Map<Id, Candidate__c> candidates;

    ByScore(Map<Id, Candidate__c> candidates) {
      this.candidates = candidates;
    }

    public Integer compare(
      ScoringService.Breakdown a,
      ScoringService.Breakdown b
    ) {
      if (a.score != b.score) {
        return a.score > b.score ? -1 : 1;
      }
      if (a.matchedMustHave.size() != b.matchedMustHave.size()) {
        return a.matchedMustHave.size() > b.matchedMustHave.size() ? -1 : 1;
      }
      return candidates.get(a.candidateId)
        .Name.compareTo(candidates.get(b.candidateId).Name);
    }
  }
}
