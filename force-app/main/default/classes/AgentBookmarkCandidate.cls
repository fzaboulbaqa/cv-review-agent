/**
 * Agent action: bookmarks a candidate's application with the recruiter's notes. Runs the same
 * Create_Bookmark flow as the Bookmark button (one bookmark per recruiter and application), and
 * logs the decision for the audit.
 */
public with sharing class AgentBookmarkCandidate {
  public class Request {
    @InvocableVariable(
      required=true
      label='Applicant ID'
      description='The application (Job Applicant) id, given in the comparison or by Find Candidates with a job.'
    )
    public String applicantId;

    @InvocableVariable(
      label='Notes'
      description='The recruiter\'s notes for the bookmark. Ask for them before bookmarking.'
    )
    public String notes;
  }

  public class Result {
    @InvocableVariable(
      label='Result'
      description='Whether the bookmark was created or already existed.'
    )
    public String message;

    @InvocableVariable(label='Bookmark ID')
    public String bookmarkId;
  }

  @InvocableMethod(
    label='Bookmark Candidate'
    description='Saves a bookmark of a candidate for a job with the overview, score, reasoning, date and the recruiter\'s notes. Only after the recruiter confirms.'
    category='CV Review Agent'
  )
  public static List<Result> bookmark(List<Request> requests) {
    List<Result> results = new List<Result>();
    for (Request request : requests) {
      Result result = new Result();
      try {
        Id applicantId = AgentInputs.toId(
          request.applicantId,
          Job_Applicant__c.SObjectType,
          'job applicant'
        );
        List<Job_Applicant__c> applicants = [
          SELECT Candidate__r.Name, Job__r.Name, Score__c
          FROM Job_Applicant__c
          WHERE Id = :applicantId
          WITH USER_MODE
        ];
        if (applicants.isEmpty()) {
          throw new AgentInputs.InputException(
            'This application was not found.'
          );
        }
        Job_Applicant__c applicant = applicants[0];

        String notes = null;
        if (request.notes != null) {
          notes = request.notes.left(32768);
        }
        Map<String, Object> flowInputs = new Map<String, Object>{
          'jobApplicantId' => applicantId,
          'notes' => notes
        };
        Flow.Interview.Create_Bookmark interview = new Flow.Interview.Create_Bookmark(
          flowInputs
        );
        interview.start();
        result.bookmarkId = (String) interview.getVariableValue('bookmarkId');
        Boolean already =
          interview.getVariableValue('alreadyBookmarked') == true;

        String who = applicant.Candidate__r.Name;
        who += ' for ' + applicant.Job__r.Name;
        String message;
        if (already) {
          message = 'You had already bookmarked ' + who;
          message += ' (bookmarkId: ' + result.bookmarkId + ').';
          message += ' Your notes were not changed: edit them on the bookmark.';
        } else {
          message = 'Bookmarked ' + who;
          message += ' (score ' + applicant.Score__c + ').';
          message += ' bookmarkId: ' + result.bookmarkId;
        }
        result.message = message;
        Logger.info('Agent decision: ' + result.message)
          .addTag(Constants.LOG_TAG_AGENT_DECISION);
        Logger.saveLog();
      } catch (Exception ex) {
        result.message = AgentInputs.failure('Bookmark Candidate', ex);
      }
      results.add(result);
    }
    return results;
  }
}
