/**
 * Agent action: creates the Candidate Card of existing candidates from their CV. Fills the empty
 * card fields, adds the skills found in the CV, flags missing, inferred and conflicting data,
 * then scores their applications. Never overwrites a value already on the record.
 * See CvExtractionService.
 */
public with sharing class AgentCreateCandidateCard {
  public class Request {
    @InvocableVariable(
      label='Candidate IDs'
      description='The candidates whose card to create, separated by commas. Use Find Candidates to get them. Leave empty when a job id is given.'
    )
    public String candidateIds;

    @InvocableVariable(
      label='Job ID'
      description='Optional. Creates the cards of all applicants of this job whose card was not created from their CV yet.'
    )
    public String jobId;
  }

  public class Result {
    @InvocableVariable(
      label='Summary'
      description='One line per candidate: fields filled, skills added, and the missing, inferred and conflicting data found.'
    )
    public String message;
  }

  @InvocableMethod(
    label='Create Candidate Card'
    description='Reads the CV attached to existing candidates and fills their Candidate Card: the empty fields (title, summary, years of experience, experience, education, achievements, contact data), the skills, and the missing, inferred and conflicting data. Values already on the record are kept. Then scores their applications.'
    category='CV Review Agent'
  )
  public static List<Result> create(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        List<Id> candidateIds = AgentInputs.toIds(
          request.candidateIds,
          Candidate__c.SObjectType,
          'candidate'
        );
        Id jobId = AgentInputs.toOptionalId(
          request.jobId,
          Job__c.SObjectType,
          'job'
        );
        if (candidateIds.isEmpty() && jobId == null) {
          throw new AgentInputs.InputException(
            'Which candidate? Give me a candidate or a job.'
          );
        }
        CvExtractionService.FillResult fillResult;
        if (candidateIds.isEmpty()) {
          fillResult = CvExtractionService.fillJobApplicants(jobId);
        } else {
          fillResult = CvExtractionService.fillCards(candidateIds);
        }
        result.message = summarize(fillResult);
      } catch (Exception ex) {
        result.message = AgentInputs.failure('Create Candidate Card', ex);
      }
      results.add(result);
    }
    return results;
  }

  private static String summarize(CvExtractionService.FillResult result) {
    List<String> lines = new List<String>();
    for (CvExtractionService.Outcome outcome : result.outcomes) {
      lines.add('- ' + outcome.message);
    }
    if (!result.notDone.isEmpty()) {
      lines.add(
        'Not done yet (at most ' +
          CvExtractionService.MAX_CANDIDATES_PER_REQUEST +
          ' cards per request): ' +
          String.join(result.notDone, ', ') +
          '. Ask again to continue.'
      );
    }
    if (result.alreadyDoneCount > 0) {
      lines.add(
        result.alreadyDoneCount +
          ' applicant(s) already have a card from their CV. ' +
          'Name them to read their CV again.'
      );
    }
    if (lines.isEmpty()) {
      return 'This job has no applicants yet.';
    }
    return String.join(lines, '\n');
  }
}
