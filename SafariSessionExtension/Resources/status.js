"use strict";

browser.browserAction.getTitle({}).then(title => {
  if (title && title !== "GPT Account Manager") document.querySelector("p").textContent = title;
}).catch(() => {});
