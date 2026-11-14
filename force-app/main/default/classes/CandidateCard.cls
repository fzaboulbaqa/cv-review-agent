// The Candidate Card: what the AI must return for one CV.
// The JSON shape is described in docs/DESIGN.md. Field names here must match the JSON keys.
public with sharing class CandidateCard {
    public CardField fullName;
    public CardField email;
    public CardField phone;
    public CardField location;
    public CardField currentTitle;
    public CardField summary;
    public List<Skill> skills;
    public List<Experience> experience;
    public List<Education> education;
    public List<Certification> certifications;
    public List<Conflict> conflicts;
    public String cvText;

    // status is one of: found, inferred, missing (and unverified, set by CardValidator)
    public class CardField {
        public String value;
        public String status;
        public String evidence;
        public String note;
    }

    public class Skill {
        public String name;
        public String evidence;
    }

    public class Experience {
        public String title;
        public String company;
        public String startDate;
        public String endDate;
        public Boolean isCurrent;
        public String evidence;
        public String status;
    }

    public class Education {
        public String degree;
        public String school;
        public Integer startYear;
        public Integer endYear;
        public String evidence;
    }

    public class Certification {
        public String name;
        public String evidence;
    }

    public class Conflict {
        public String field;
        public String detail;
        public String evidence;
    }

    public static CandidateCard parse(String jsonText) {
        CandidateCard card = (CandidateCard) JSON.deserialize(jsonText, CandidateCard.class);
        card.fillGaps();
        return card;
    }

    // The 6 simple fields, by name. Used to loop over them in the validator.
    public Map<String, CardField> simpleFields() {
        return new Map<String, CardField>{
            'fullName' => fullName,
            'email' => email,
            'phone' => phone,
            'location' => location,
            'currentTitle' => currentTitle,
            'summary' => summary
        };
    }

    // The AI can leave things out. After this, no list and no simple field is null,
    // and an empty value is always marked as missing.
    private void fillGaps() {
        fullName = cleanField(fullName);
        email = cleanField(email);
        phone = cleanField(phone);
        location = cleanField(location);
        currentTitle = cleanField(currentTitle);
        summary = cleanField(summary);
        if (skills == null) {
            skills = new List<Skill>();
        }
        if (experience == null) {
            experience = new List<Experience>();
        }
        if (education == null) {
            education = new List<Education>();
        }
        if (certifications == null) {
            certifications = new List<Certification>();
        }
        if (conflicts == null) {
            conflicts = new List<Conflict>();
        }
        if (cvText == null) {
            cvText = '';
        }
    }

    private static CardField cleanField(CardField field) {
        if (field == null) {
            field = new CardField();
        }
        if (String.isBlank(field.value)) {
            field.value = null;
            field.status = 'missing';
        } else if (field.status == null) {
            field.status = 'found';
        } else {
            field.status = field.status.toLowerCase();
        }
        return field;
    }
}
