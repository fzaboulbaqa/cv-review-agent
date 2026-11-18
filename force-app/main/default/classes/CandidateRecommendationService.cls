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
    Job__c job = loadJob(jobId);

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
    for (ScoringService.Breakdown breakdown : breakdowns) {
      Integer rank = result.ranking.size() + 1;
      String candidateName = candidates.get(breakdown.candidateId).Name;
      result.ranking.add(toRanked(breakdown, rank, candidateName));
    }
    Ranked top = result.ranking[0];
    result.topApplicantId = top.applicantId;
    result.hasStrongMatch = top.score >= Constants.MATCH_STRONG_SCORE;

    // 1. AI first (no DML before a callout).
    Map<Id, String> aiReasoning = askAi(job, result, candidates);
    if (!result.aiAvailable) {
      result.recommendation =
        'The AI recommendation is not available right now. The ranking below comes from the ' +
        'scoring rules only.';
    }

    // 2. Save scores and missing reasonings, only for candidates whose card was filled from a
    // CV: a score is locked once saved, and an empty card would lock a score of 0.
    List<ScoringService.Breakdown> ready = new List<ScoringService.Breakdown>();
    for (ScoringService.Breakdown breakdown : breakdowns) {
      Candidate__c candidate = candidates.get(breakdown.candidateId);
      if (String.isNotBlank(candidate.CV_Text__c)) {
        ready.add(breakdown);
      } else {
        aiReasoning.remove(breakdown.jobApplicantId);
      }
    }
    ScoringService.saveScores(ready);
    saveReasoning(result.ranking, aiReasoning);

    String message = 'Agent decision: recommendation for job ' + job.Name;
    message += ' (' + jobId + ').';
    message += ' Ranking: ' + rankingLine(result.ranking) + '.';
    message += ' Strong match: ' + result.hasStrongMatch + '.';
    message += ' AI text: ' + result.aiAvailable;
    Logger.info(message).addTag(Constants.LOG_TAG_AGENT_DECISION);
    Logger.saveLog();
    return result;
  }

  private static Job__c loadJob(Id jobId) {
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
    return jobs[0];
  }

  private static Ranked toRanked(
    ScoringService.Breakdown breakdown,
    Integer rank,
    String candidateName
  ) {
    Ranked ranked = new Ranked();
    ranked.rank = rank;
    ranked.applicantId = breakdown.jobApplicantId;
    ranked.candidateId = breakdown.candidateId;
    ranked.candidateName = candidateName;
    ranked.score = breakdown.score;
    ranked.matchLevel = Constants.matchLevel(breakdown.score);
    ranked.breakdown = explain(breakdown);
    return ranked;
  }

  /**
   * Asks the AI for the recommendation text (set on the result) and returns the reasoning it
   * wrote per applicant. If the AI fails, the error is logged and nothing is thrown.
   */
  private static Map<Id, String> askAi(
    Job__c job,
    Recommendation result,
    Map<Id, Candidate__c> candidates
  ) {
    Set<Id> rankedApplicantIds = new Set<Id>();
    for (Ranked ranked : result.ranking) {
      rankedApplicantIds.add(ranked.applicantId);
    }

    Map<Id, String> aiReasoning = new Map<Id, String>();
    try {
      Map<String, Object> inputs = new Map<String, Object>{
        'Job' => describeJob(job),
        'Applicants' => describeApplicants(result.ranking, candidates)
      };
      String rawAnswer = AiPrompt.run(Constants.TEMPLATE_RECOMMEND, inputs);
      Map<String, Object> answer = AiPrompt.parseJsonObject(rawAnswer);

      String text = AiPrompt.text(answer, 'recommendation');
      if (text != null) {
        result.recommendation = AiPrompt.withoutCourtesy(text);
      }
      result.aiAvailable = result.recommendation != null;

      for (Map<String, Object> item : AiPrompt.objects(answer, 'applicants')) {
        Id applicantId = toId(AiPrompt.text(item, 'applicantId'));
        String reasoning = AiPrompt.text(item, 'reasoning');
        // Only Ids we sent: the AI can't attach a reasoning to another record.
        Boolean isKnownApplicant = rankedApplicantIds.contains(applicantId);
        if (applicantId != null && isKnownApplicant && reasoning != null) {
          aiReasoning.put(applicantId, reasoning);
        }
      }
    } catch (Exception ex) {
      Logger.error('AI recommendation failed for job ' + job.Id)
        .setExceptionDetails(ex)
        .addTag(Constants.LOG_TAG_AGENT_DECISION);
    }
    return aiReasoning;
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
      String years = yearsText(breakdown.candidateYears);
      lines.add(
        'Experience: ' + years + ' for ' + breakdown.requiredYears + ' required'
      );
    }

    if (lines.isEmpty()) {
      lines.add(
        'The job has no skills or minimum experience to score against.'
      );
    }
    return String.join(lines, '\n');
  }

  private static String yearsText(Decimal candidateYears) {
    if (candidateYears == null) {
      return 'not stated in the CV (0 points, check in interview)';
    }
    return candidateYears + ' years';
  }

  private static Id toId(String value) {
    if (value == null) {
      return null;
    }
    try {
      return Id.valueOf(value);
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
    Integer total = matched.size() + missing.size();
    String counts = matched.size() + ' of ' + total;
    String details = String.join(parts, '; ');
    return label + ': ' + counts + ' (' + details + ')';
  }

  private static void saveReasoning(
    List<Ranked> ranking,
    Map<Id, String> aiReasoning
  ) {
    Set<Id> applicantIds = new Set<Id>();
    for (Ranked ranked : ranking) {
      applicantIds.add(ranked.applicantId);
    }
    Set<Id> withoutReasoning = applicantsWithoutReasoning(applicantIds);

    List<Job_Applicant__c> updates = new List<Job_Applicant__c>();
    for (Ranked ranked : ranking) {
      // Without the AI text, wait for a later comparison: the reasoning is written once.
      Boolean reasoningIsEmpty = withoutReasoning.contains(ranked.applicantId);
      Boolean hasAiText = aiReasoning.containsKey(ranked.applicantId);
      if (reasoningIsEmpty && hasAiText) {
        String reasoning = reasoningText(
          ranked,
          aiReasoning.get(ranked.applicantId)
        );
        updates.add(
          new Job_Applicant__c(
            Id = ranked.applicantId,
            Reasoning__c = reasoning
          )
        );
      }
    }
    update as user updates;
  }

  /** The applicants (among these) whose Reasoning__c is still empty. */
  private static Set<Id> applicantsWithoutReasoning(Set<Id> applicantIds) {
    // Long text can't be filtered in SOQL: the empty ones are picked in Apex.
    Set<Id> result = new Set<Id>();
    for (Job_Applicant__c applicant : [
      SELECT Id, Reasoning__c
      FROM Job_Applicant__c
      WHERE Id IN :applicantIds
      WITH USER_MODE
    ]) {
      if (String.isBlank(applicant.Reasoning__c)) {
        result.add(applicant.Id);
      }
    }
    return result;
  }

  private static String reasoningText(Ranked ranked, String aiText) {
    List<String> lines = new List<String>();
    lines.add('Score: ' + ranked.score + ' (' + ranked.matchLevel + ')');
    lines.add('Score breakdown:');
    lines.add(ranked.breakdown);
    lines.add('');
    lines.add(aiText);
    String text = String.join(lines, '\n');
    return text.left(Constants.LONG_TEXT_MAX_LENGTH);
  }

  private static String describeJob(Job__c job) {
    List<String> must = new List<String>();
    List<String> nice = new List<String>();
    for (Job_Skill__c jobSkill : job.Job_Skills__r) {
      if (jobSkill.Importance__c == Constants.IMPORTANCE_MUST_HAVE) {
        must.add(jobSkill.Skill__r.Name);
      } else {
        nice.add(jobSkill.Skill__r.Name);
      }
    }

    String minYears = 'none';
    if (job.Min_Years_Experience__c != null) {
      minYears = String.valueOf(job.Min_Years_Experience__c);
    }
    String description = '(none)';
    if (job.Description__c != null) {
      description = job.Description__c.left(4000);
    }

    List<String> lines = new List<String>();
    lines.add('Job: ' + job.Name);
    lines.add('Minimum years of experience: ' + minYears);
    lines.add('Must-have skills: ' + joinOrNone(must, ', '));
    lines.add('Nice-to-have skills: ' + joinOrNone(nice, ', '));
    lines.add('Description:');
    lines.add(description);
    return String.join(lines, '\n');
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
      parts.add(describeApplicant(ranked, candidate));
    }
    return String.join(parts, '\n\n');
  }

  private static String describeApplicant(
    Ranked ranked,
    Candidate__c candidate
  ) {
    List<String> lines = new List<String>();
    lines.add('Rank ' + ranked.rank + ': ' + ranked.candidateName);
    lines.add('applicantId: ' + ranked.applicantId);
    lines.add('Score: ' + ranked.score + ' of 100 (' + ranked.matchLevel + ')');
    lines.add('Score breakdown:');
    lines.add(ranked.breakdown);
    lines.add('Data issues on the card: ' + flagSummary(candidate));
    lines.add('CV text:');
    lines.add('"""');
    lines.add(cvTextForAi(candidate));
    lines.add('"""');
    return String.join(lines, '\n');
  }

  /** The CV text, cut, with triple quotes escaped so it can't close the quoted block. */
  private static String cvTextForAi(Candidate__c candidate) {
    if (String.isBlank(candidate.CV_Text__c)) {
      return '(No CV text available.)';
    }
    String cvText = candidate.CV_Text__c.left(MAX_CV_CHARS);
    return cvText.replace('"""', '\'\'\'');
  }

  private static String flagSummary(Candidate__c candidate) {
    List<String> items = new List<String>();
    for (Extraction_Flag__c item : candidate.Extraction_Flags__r) {
      String detail = item.Detail__c.left(200);
      items.add(item.Type__c + ' ' + item.Field__c + ': ' + detail);
    }
    return joinOrNone(items, ' | ');
  }

  /** The items joined with the separator, or 'none' when there are none. */
  private static String joinOrNone(List<String> items, String separator) {
    if (items.isEmpty()) {
      return 'none';
    }
    return String.join(items, separator);
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
    List<Candidate__c> records = [
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
    ];
    return new Map<Id, Candidate__c>(records);
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
        return biggerFirst(a.score, b.score);
      }
      Integer mustA = a.matchedMustHave.size();
      Integer mustB = b.matchedMustHave.size();
      if (mustA != mustB) {
        return biggerFirst(mustA, mustB);
      }
      String nameA = candidates.get(a.candidateId).Name;
      String nameB = candidates.get(b.candidateId).Name;
      return nameA.compareTo(nameB);
    }

    /** Sort order for two different values: the bigger one comes first. */
    private Integer biggerFirst(Integer first, Integer second) {
      if (first > second) {
        return -1;
      }
      return 1;
    }
  }
}
