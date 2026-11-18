/**
 * Answers a recruiter's question about one or several candidates, using their CV text only.
 *
 * Grounding: the AI (template CV_Answer_Question) gets the question and the CV text of each
 * candidate, numbered as sources. It must quote the CV for every claim, name the candidate it
 * comes from, and say "not stated in the CV" instead of guessing. The CV text is treated as data:
 * instructions written inside a CV are ignored (prompt injection).
 *
 * Which candidates: the given ones, else the applicants of the given job, else the most recently
 * updated candidates (capped, and the answer says so).
 */
public with sharing class CandidateQuestionService {
  @TestVisible
  private static final Integer MAX_CANDIDATES = 20;
  @TestVisible
  private static final Integer MAX_CV_CHARS = 12000;

  public class Answer {
    public String answer;
    public List<String> candidateNames = new List<String>();
    /** Sources that were cut or left out, said to the recruiter. */
    public String note;
  }

  public class QuestionException extends Exception {
  }

  public static Answer ask(String question, List<Id> candidateIds, Id jobId) {
    if (String.isBlank(question)) {
      throw new QuestionException('Please ask a question.');
    }
    List<Candidate__c> candidates = candidates(candidateIds, jobId);
    if (candidates.isEmpty()) {
      if (jobId != null) {
        throw new QuestionException('This job has no applicants yet.');
      }
      throw new QuestionException('No matching candidate found.');
    }

    Answer result = new Answer();
    List<String> sources = new List<String>();
    List<String> notes = new List<String>();
    Integer index = 1;
    for (Candidate__c candidate : candidates) {
      result.candidateNames.add(candidate.Name);
      String cvText = candidate.CV_Text__c;
      if (String.isBlank(cvText)) {
        cvText = '(No CV text: the card of this candidate was not created from a CV yet.)';
        notes.add(candidate.Name + ' has no CV text');
      } else if (cvText.length() > MAX_CV_CHARS) {
        cvText = cvText.left(MAX_CV_CHARS) + '\n(CV cut here: too long)';
        notes.add('the CV of ' + candidate.Name + ' was cut');
      }
      sources.add(source(index, candidate.Name, cvText));
      index++;
    }

    Boolean searchedRecentOnly = candidateIds.isEmpty() && jobId == null;
    if (searchedRecentOnly && candidates.size() == MAX_CANDIDATES) {
      notes.add(
        'only the ' +
          MAX_CANDIDATES +
          ' most recently updated candidates were searched'
      );
    }

    Map<String, Object> inputs = new Map<String, Object>{
      'Question' => question.left(2000),
      'Candidates' => String.join(sources, '\n\n')
    };
    result.answer = AiPrompt.run(Constants.TEMPLATE_ANSWER_QUESTION, inputs);
    if (!notes.isEmpty()) {
      result.note = 'Note: ' + String.join(notes, '; ') + '.';
    }

    String names = String.join(result.candidateNames, ', ');
    String message = 'Agent answered a question about ' + names;
    message += '. Question: ' + question.left(500);
    Logger.info(message).addTag(Constants.LOG_TAG_AGENT_DECISION);
    Logger.saveLog();
    return result;
  }

  /** One numbered source for the AI. Triple quotes are escaped so the CV can't close the block. */
  private static String source(Integer index, String name, String cvText) {
    List<String> lines = new List<String>();
    lines.add('[' + index + '] Candidate: ' + name);
    lines.add('CV text:');
    lines.add('"""');
    lines.add(cvText.replace('"""', '\'\'\''));
    lines.add('"""');
    return String.join(lines, '\n');
  }

  private static List<Candidate__c> candidates(
    List<Id> candidateIds,
    Id jobId
  ) {
    if (!candidateIds.isEmpty()) {
      return [
        SELECT Id, Name, CV_Text__c
        FROM Candidate__c
        WHERE Id IN :candidateIds
        WITH USER_MODE
        ORDER BY Name
        LIMIT :MAX_CANDIDATES
      ];
    }
    if (jobId != null) {
      List<Candidate__c> result = new List<Candidate__c>();
      for (Job_Applicant__c applicant : [
        SELECT Candidate__r.Id, Candidate__r.Name, Candidate__r.CV_Text__c
        FROM Job_Applicant__c
        WHERE Job__c = :jobId
        WITH USER_MODE
        ORDER BY Score__c DESC NULLS LAST, Candidate__r.Name
        LIMIT :MAX_CANDIDATES
      ]) {
        result.add(applicant.Candidate__r);
      }
      return result;
    }
    return [
      SELECT Id, Name, CV_Text__c
      FROM Candidate__c
      WITH USER_MODE
      ORDER BY LastModifiedDate DESC
      LIMIT :MAX_CANDIDATES
    ];
  }
}
