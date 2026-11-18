# CV Review Agent (Salesforce)

A careers portal where candidates apply with their CV, and an Agentforce agent that helps HR fill
Candidate Cards, ask questions about the CVs, compare applicants and bookmark them.

## Architecture overview

- **Careers portal** (Experience Cloud, guest): 3 LWCs (job list, job detail, apply form).
  `CareersApplicationService` creates the Candidate, the Job Applicant and the CV file.
- **Recruiter app** (Clouding HR): `candidateCard` and `jobApplicants` LWCs, Bookmark screen flow.
- **Agent** (Agent Script): a router and 3 subagents (Candidate Cards, Candidate Questions,
  Compare Recommend and Bookmark), 6 Apex invocable actions.
- **Services:** `CvTextReader`, `CvExtractionService`, `ScoringService`,
  `CandidateQuestionService`, `CandidateRecommendationService`.
- **AI:** 4 Prompt Builder templates, all called through one class (`AiPrompt`).
- **Logging:** Nebula Logger, every answer, recommendation and bookmark (tag `Agent Decision`).

## Data model and Candidate Card design

- **Job** and **Candidate**, joined by **Job Applicant** (score and reasoning).
- **Skill**: shared list. **Job Skill** (Must Have / Nice To Have) and **Candidate Skill**.
- **Extraction Flag** under a Candidate: Missing, Inferred or Conflict.
- **Bookmark**: lookup to a Job Applicant, private to each recruiter.
- The card shows the title, years, summary, experience, education, skills and data quality flags.
- The CV text is stored once on the Candidate, so questions and comparisons don't re-read the file.

## Key design decisions and trade-offs

- **The agent fills, it doesn't create:** the portal creates candidates, the agent fills only
  empty fields. A difference with the record becomes a Conflict flag.
- **Scoring by rules, not AI:** 60 must-have, 20 nice-to-have, 20 years. Same data, same score.
  The AI only writes the recommendation.
- **A score is set once** (validation rule), so a bookmark keeps the score the recruiter saw.
- **No automatic rejection:** a person decides.
- **No triggers:** all writes come from the portal and the agent, so the logic sits in services.
- **Security:** `with sharing` and user mode everywhere, except the portal service (narrow,
  validates every field, returns no data).
- **Prompt templates instead of prompts in Apex:** easier to read and change.

## Assumptions made

- The latest CV file of a candidate is the current one.
- Skills match by name.
- Recruiters work as one team, so candidates are shared.
- One candidate per email: a second application is added to the same record.

## Known limitations

- At most 3 cards per agent request (AI calls are synchronous).
- Old `.doc` files can't be read: PDF, DOCX and TXT only.
- Q&A reads at most 20 candidates and 12,000 characters per CV.
- Scoring weights are in code.

## Testing approach

- One test class for each apex class, data from `TestDataFactory`.
- Prompts checked by hand on real CVs: clean, messy, DOCX.

## With more time

- **Background processing** (Queueable), to fill hundreds of cards at once.
- **Trigger handler framework**, once records come from imports and integrations.
- **Score history**, so a new CV gives a new score without losing the old one.
- **Scoring weights in Custom Metadata**, so HR can tune them without a deploy.
- **A CV quote on each skill**, to show where it was found.
- **Candidate login** on the portal, to follow their applications.
- **AI usage and cost dashboard**, per job and per recruiter.
- **More declarative checks:** validation, duplicate and matching rules.
