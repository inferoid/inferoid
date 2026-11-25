const smallTalkWords = new Set([
  "a", "about", "afternoon", "all", "am", "an", "and", "are", "assistant", "bye", "can", "do", "doing", "evening",
  "fine", "for", "going", "good", "great", "hello", "help", "helpful", "hey", "hi", "how", "i", "inferoid", "is",
  "it", "me", "morning", "much", "my", "name", "nice", "night", "ok", "okay", "please", "so", "tell", "thank",
  "thanks", "that", "the", "there", "to", "today", "up", "very", "well", "what", "who", "yo", "you", "your", "yourself"
]);

export function needsRecords(question: string): boolean {
  const normalized = question.toLowerCase().replace(/'s\b/g, " is").replace(/'re\b/g, " are").replace(/'m\b/g, " am");
  const words = normalized.split(/[^\p{L}\p{N}]+/u).filter(Boolean);
  return words.length > 0 && !words.every((word) => smallTalkWords.has(word));
}
