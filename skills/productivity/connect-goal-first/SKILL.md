---
name: connect-goal-first
description: Use when someone wants to connect an app, device or account.
version: 1.0.0
metadata:
  hermes:
    tags: [connections, setup, experimental]
---

# Connect something: goal first, method second

Ships with One. Use it whenever the person asks to connect something (an app, a device, an account,
a service), including every "Something else…" request from the Connections screen. Talk in plain
words: no commands, no file paths, no jargon unless they ask.

## Why this exists
People name a thing ("my phone", "my texts"), not a goal. If you pick a method from the thing, you can
build something that works and still does nothing they wanted. Example: someone said "my texts", got
their phone paired so the assistant could READ their texts, and only at the end said what they really
wanted: the assistant should be able to text THEM. That method could never do it. Ask the goal first.

## Steps
1. **Ask the goal. One question, before anything else.** Ask what they want to happen, and in which
   direction. For example: "What do you want to happen? For example: I text you, you read my texts,
   you reply for me, you remind me." Offer tap-choices built from real outcomes for that thing, not
   data types. Good: "You text me when something needs me", "You read my texts", "You reply for me".
   Bad: "Texts", "Notifications", "Calls", "Photos".
2. **Say the goal back in one line and get a yes.** "So you want me to be able to text you when
   something needs you. Right?" Don't build anything until they say yes.
3. **Ask what they use, only if it matters** for the method (for example which phone, which app).
4. **Pick the method that delivers THAT goal.** Check the direction before you choose:
   - Who sends and who receives?
   - From whose number or account does it go out?
   - Does it work when the Mac is asleep or the person is away?
   Then say plainly, up front, what the method can't do. "This lets me read your texts. It can't send
   you a text from me."
5. **If no free method fits, say so.** Give the honest options with their cost, in plain words, and
   let them pick. Never quietly build a free method that does something else.
6. Then the usual connection steps:
   - Say in one line that this is experimental, built by you, may break.
   - Find the simplest way in: an official app or command-line tool on this Mac, an API, an export,
     or their own browser. Do every step you can yourself.
   - Logins go through their password manager or the app's own sign-in. Never put a password or code
     into the chat. Still ask before any money, sending, posting or deleting.
   - Test it for real. For read goals: one read-only check. For send goals: one test message, after
     they say yes to exactly what it says and where it goes.
   - Save it as a skill in `skills/my-connections/<short-name>/SKILL.md`: the goal, how it works,
     what it can't do, what's off-limits.
   - Only if the test passed, add it to `connections.json` so it shows up as Experimental.

## Worked example: Phone
**Wrong path.** "What phone do you use?" "What do you want to reach on it: texts, notifications,
calls, photos?" They tap "My texts". You pair Google Messages for web so you can read their texts,
run a test where only old texts sync, and ask them to "send yourself a text". At the end it turns out
they wanted you to text them, which Google Messages can't do: it only sends from their own number.

**Right path.**
1. "What do you want to happen? [choices: You text me | You read my texts | You reply for me | You remind me]"
2. They tap "You text me". "So you want me to be able to text you when something needs you. Right?"
3. Direction: you send, they receive, from a number that isn't theirs. Reading their texts doesn't
   help, so pairing their phone is the wrong tool.
4. Options, honestly:
   - Free: their carrier's email-to-text address (for example number@vtext.com, @tmomail.net,
     @txt.att.net). You send an email and it arrives as a text. Can't do: replies may not come back,
     some carriers drop or delay these, and it needs an email account you can send from.
   - Paid: a texting service like Twilio. About a dollar a month for a number plus about a cent per
     text, and a sign-up they do themselves. Can do: texts from a real number, replies can come back.
5. They pick one. Ask before the one test text, send it, and ask them to say when it arrived.

## Pitfalls
- Never ask the person to do a test step without first saying in one plain line why it's needed.
- Never present a half-passed test as progress. Say what it means for their goal: "Only old texts came
  through, so I can't promise I'll see new ones."
- Don't ask for the device or app first. Goal first, then what they use.
- Don't offer data types as choices ("texts", "photos"). Offer outcomes ("You text me").
- A method that works but points the wrong way (reads when they wanted to be told) is a failure, not
  a partial success.
