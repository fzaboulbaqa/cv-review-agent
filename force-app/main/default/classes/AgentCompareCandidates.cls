/**
 * Agent action: compares the applicants of a job and recommends one or more, with the score
 * breakdown, strengths, concerns, trade-offs and gaps to check in interview.
 * See CandidateRecommendationService.
 */
public with sharing class AgentCompareCandidates {
  public class Request {
    @InvocableVariable(
      required=true
      label='Job ID'
      description='The job (role) to compare the candidates for.'
    )
    public String jobId;

    @InvocableVariable(
      label='Candidate IDs'
      description='Optional. Compare only these applicants (comma separated). Empty: all applicants of the job.'
    )
    public String candidateIds;
  }

  public class Result {
    @InvocableVariable(
      label='Recommendation'
      description='Recommendation, then the ranking with score, match level, breakdown and applicantId of each candidate.'
    )
    public String message;

    @InvocableVariable(
      label='Top Applicant ID'
      description='Application id of the best ranked candidate, for a bookmark.'
    )
    public String topApplicantId;
  }

  @InvocableMethod(
    label='Compare and Recommend Candidates'
    description='Ranks the applicants of a job with the scoring rules (must-have skills 60, nice-to-have 20, experience 20), explains each score, and recommends one or more candidates with strengths, concerns, trade-offs and the gaps to check in interview. If no one is a strong match, gives the best available option and the risks.'
    category='CV Review Agent'
  )
  public static List<Result> compare(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        Id jobId = AgentInputs.toId(request.jobId, Job__c.SObjectType, 'job');
        Set<Id> candidateIds = new Set<Id>(
          AgentInputs.toIds(
            request.candidateIds,
            Candidate__c.SObjectType,
            'candidate'
          )
        );
        CandidateRecommendationService.Recommendation recommendation = CandidateRecommendationService.recommend(
          jobId,
          candidateIds
        );
        result.message = format(recommendation);
        result.topApplicantId = recommendation.topApplicantId;
      } catch (CandidateRecommendationService.RecommendationException ex) {
        result.message = ex.getMessage();
      } catch (Exception ex) {
        result.message = AgentInputs.failure('Compare Candidates', ex);
      }
      results.add(result);
    }
    return results;
  }

  private static String format(
    CandidateRecommendationService.Recommendation recommendation
  ) {
    List<String> lines = new List<String>{
      'Job: ' + recommendation.jobName,
      recommendation.hasStrongMatch
        ? ''
        : 'No applicant is a strong match (score ' +
          Constants.MATCH_STRONG_SCORE +
          ' or more): the best available option is shown with its gaps.',
      recommendation.recommendation,
      '',
      'Ranking (scores from the scoring rules, not from the AI):'
    };
    for (
      CandidateRecommendationService.Ranked ranked : recommendation.ranking
    ) {
      lines.add(
        ranked.rank +
          '. ' +
          ranked.candidateName +
          ': ' +
          ranked.score +
          '/100, ' +
          ranked.matchLevel +
          ' (applicantId: ' +
          ranked.applicantId +
          ')\n   ' +
          ranked.breakdown.replace('\n', '\n   ')
      );
    }
    return String.join(lines, '\n').replace('\n\n\n', '\n\n');
  }
}
