/** Agent action: answers a question about one or several candidates from their CVs only. */
public with sharing class AgentAskAboutCandidates {
  public class Request {
    @InvocableVariable(
      required=true
      label='Question'
      description='The recruiter\'s question, as asked.'
    )
    public String question;

    @InvocableVariable(
      label='Candidate IDs'
      description='Optional. The candidates the question is about, separated by commas.'
    )
    public String candidateIds;

    @InvocableVariable(
      label='Job ID'
      description='Optional. Ask about all applicants of this job (used when no candidate ids are given).'
    )
    public String jobId;
  }

  public class Result {
    @InvocableVariable(
      label='Answer'
      description='Answer grounded in the CVs, with quotes and the candidate each fact comes from.'
    )
    public String answer;
  }

  @InvocableMethod(
    label='Answer Question About Candidates'
    description='Answers a question about one candidate, several candidates, the applicants of a job, or all candidates, using only the text of their CVs, with quotes as references. Says when the CV does not contain the answer.'
    category='CV Review Agent'
  )
  public static List<Result> ask(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        CandidateQuestionService.Answer answer = CandidateQuestionService.ask(
          request.question,
          AgentInputs.toIds(
            request.candidateIds,
            Candidate__c.SObjectType,
            'candidate'
          ),
          AgentInputs.toOptionalId(request.jobId, Job__c.SObjectType, 'job')
        );
        result.answer =
          answer.answer + (answer.note == null ? '' : '\n\n' + answer.note);
      } catch (CandidateQuestionService.QuestionException ex) {
        result.answer = ex.getMessage();
      } catch (Exception ex) {
        result.answer = AgentInputs.failure('Answer Question', ex);
      }
      results.add(result);
    }
    return results;
  }
}
