---
name: define-selected-term
description: A selected term in a news article gets a one-line chip answer from Quick, no handoff.
tags: [quick, define, chip, routing]
runs: 3
max_turns: 2
allowed_tools: [Read]
append_system_prompt: "Follow the buddy-answer skill for every message that contains a <buddy-packet>."
---
<buddy-packet>
{"v":1,"utterance":"what does this mean?","app":{"name":"Safari","bundle":"com.apple.Safari","kind":"browser"},"window":{"title":"Central banks keep shrinking their balance sheets"},"browser":{"url":"https://www.example-news.com/markets/central-banks-shrink-balance-sheets","host":"www.example-news.com"},"selection":{"text":"quantitative tightening","length":23,"truncated":false},"conversation":{"id":"c_1","turn":1,"previous":[]}}
</buddy-packet>
<question>what does this mean?</question>
