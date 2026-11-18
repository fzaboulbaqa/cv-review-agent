/**
 * Values shared by several classes: picklist values, scoring thresholds, prompt template names,
 * log tags and validation patterns. One place to change them, and no typos in string literals.
 *
 * Apex only allows static members in top-level classes, so the constants are grouped by prefix.
 * The LWC match levels (candidateUtils.js) use the same thresholds as MATCH_*.
 */
public with sharing class Constants {
  // ---------- Job_Skill__c.Importance__c ----------
  public static final String IMPORTANCE_MUST_HAVE = 'Must Have';
  public static final String IMPORTANCE_NICE_TO_HAVE = 'Nice To Have';

  // ---------- Extraction_Flag__c.Type__c ----------
  public static final String FLAG_MISSING = 'Missing';
  public static final String FLAG_INFERRED = 'Inferred';
  public static final String FLAG_CONFLICT = 'Conflict';
  public static final Set<String> FLAG_TYPES = new Set<String>{
    FLAG_MISSING,
    FLAG_INFERRED,
    FLAG_CONFLICT
  };

  // ---------- Match levels (display only, never used to reject anyone) ----------
  public static final Integer MATCH_STRONG_SCORE = 75;
  public static final Integer MATCH_PARTIAL_SCORE = 50;
  public static final String MATCH_STRONG = 'Strong match';
  public static final String MATCH_PARTIAL = 'Partial match';
  public static final String MATCH_WEAK = 'Weak match';
  public static final String MATCH_NOT_SCORED = 'Not scored';

  // ---------- Prompt templates (Prompt Builder API names) ----------
  public static final String TEMPLATE_READ_CV = 'CV_Read_Text';
  public static final String TEMPLATE_EXTRACT_CARD = 'CV_Extract_Card';
  public static final String TEMPLATE_ANSWER_QUESTION = 'CV_Answer_Question';
  public static final String TEMPLATE_RECOMMEND = 'CV_Recommend';

  // ---------- Nebula Logger tags ----------
  public static final String LOG_TAG_AGENT_DECISION = 'Agent Decision';
  public static final String LOG_TAG_CV_EXTRACTION = 'CV Extraction';
  public static final String LOG_TAG_SCORING = 'Scoring';
  public static final String LOG_TAG_CAREERS = 'Careers';
  public static final String LOG_TAG_CANDIDATE_CARD = 'CandidateCard';
  public static final String LOG_TAG_JOB_APPLICANTS = 'JobApplicants';

  // ---------- Validation ----------
  /** Simple email check: something@something.tld, no spaces. */
  public static final String EMAIL_REGEX = '^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$';
  public static final Integer EMAIL_MAX_LENGTH = 80; // Candidate__c.Email__c
  public static final Integer LONG_TEXT_MAX_LENGTH = 32768; // Summary, Experience, Reasoning, ...
  /** Image file extensions (lower case), as ContentVersion.FileExtension. */
  public static final Set<String> IMAGE_EXTENSIONS = new Set<String>{
    'png',
    'jpg',
    'jpeg',
    'gif',
    'webp'
  };

  /** Match level shown next to a score. */
  public static String matchLevel(Integer score) {
    if (score == null) {
      return MATCH_NOT_SCORED;
    }
    if (score >= MATCH_STRONG_SCORE) {
      return MATCH_STRONG;
    }
    if (score >= MATCH_PARTIAL_SCORE) {
      return MATCH_PARTIAL;
    }
    return MATCH_WEAK;
  }

  public static Boolean isValidEmail(String email) {
    return email != null &&
      email.length() <= EMAIL_MAX_LENGTH &&
      Pattern.matches(EMAIL_REGEX, email);
  }
}
