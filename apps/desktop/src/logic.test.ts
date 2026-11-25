import { describe, expect, it } from "vitest";
import { needsRecords } from "./logic";

describe("chat grounding", () => {
  it("keeps small talk out of records", () => expect(["Hi", "How are you today?", "Who are you?", "Thanks!"].every((q) => !needsRecords(q))).toBe(true));
  it("grounds questions about meetings", () => expect(["What did Sara promise on Friday?", "When is the next meeting?", "What do you remember about the budget?"].every(needsRecords)).toBe(true));
});
