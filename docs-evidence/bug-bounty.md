> For the complete documentation index, see [llms.txt](https://docs.zircuit.com/llms.txt). Markdown versions of documentation pages are available by appending `.md` to page URLs; this page is available as [Markdown](https://docs.zircuit.com/info/security/bug-bounty.md).

# Bug Bounty - Zircuit Finance

We are committed to maintaining the highest security standards for our systems and our users. As part of this commitment, we are announcing the following Bug Bounty Program, detailed below. This program is designed to encourage and reward security researchers and ethical hackers for identifying and reporting potential security vulnerabilities in our systems.

**Scope:**

We welcome submissions that identify vulnerabilities in our smart contracts. Submissions should focus on finding significant security issues that could potentially impact the integrity or availability of our data, or users' funds and data.

A separate bug bounty program exists for Zircuit Core, and can be found [here](https://docs.zircuit.com/info/security/bug-bounty-zircuit-core.md).

**Rewards:**

**For smart contract vulnerabilities:**

* Critical - up to $100,000 USDC
* High - up to $50,000 USDC
* Medium - up to $10,000 USDC
* Low - up to $5,000 USDC

**Rules:**

* Do not engage in any activity that can harm Zircuit or its users.
* Provide us with a reasonable amount of time to fix the issue before any public disclosure.
* Do not exploit any vulnerability you find for any reason.
* Adhere to all applicable laws and regulations.

**Legal:**

Participation in our Bug Bounty Program is subject to our terms and conditions. By submitting a report, you agree to these terms, which include confidentiality provisions and a release of claims against Zircuit.

**Submission:**

Bug submissions can be disclosed to <bugbounty@zircuit.com>.

**Out of scope:**

* Delayed NAV updates (including racing oracle / keeper / report before price-per-share changes)
* Support ticket chatbot


---

# Agent Instructions
This documentation is published with GitBook. GitBook is the documentation platform designed so that both humans and AI agents can read, navigate, and reason over technical content effectively. Learn more at gitbook.com.

## Querying This Documentation
If you need additional information that is not directly available in this page, you can query the documentation by asking a question.

Perform an HTTP GET request on the following URL with the `ask` and `goal` query parameters:

```
GET https://docs.zircuit.com/info/security/bug-bounty.md?ask=<question>&goal=<user_goal>
```

`ask` is the immediate question: it should be specific, self-contained, and written in natural language.
`goal` is what the user is ultimately trying to achieve, the reason they need the answer. Sharing it helps GitBook give you a better, more relevant answer. A goal is most helpful when it describes the outcome the user wants rather than restating the question. For example, with `ask=how do I create an API token`, a goal like `automate deployments from our CI pipeline` lets GitBook tailor the answer to that use case.

The response will contain a direct answer to the question and relevant excerpts and sources from the documentation.

Use this mechanism when the answer is not explicitly present in the current page, you need clarification or additional context, or you want to retrieve related documentation sections.
