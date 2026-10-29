// Page language: the visitor's choice, otherwise the system language (Cydia passes it to the page).
(function () {
  var choice = null;
  try { choice = localStorage.getItem("lang"); } catch (e) {}
  var system = (navigator.language || navigator.userLanguage || "en").toLowerCase();
  var lang = choice || (system.indexOf("ru") === 0 ? "ru" : "en");
  document.documentElement.lang = lang;

  function mark() {
    var links = document.querySelectorAll(".languages a");
    for (var i = 0; i < links.length; i++)
      links[i].className = links[i].getAttribute("data-lang") === document.documentElement.lang ? "current" : "";
  }

  document.addEventListener("DOMContentLoaded", function () {
    var links = document.querySelectorAll(".languages a");
    for (var i = 0; i < links.length; i++) {
      links[i].onclick = function () {
        var picked = this.getAttribute("data-lang");
        try { localStorage.setItem("lang", picked); } catch (e) {}
        document.documentElement.lang = picked;
        mark();
        return false;
      };
    }
    mark();
  });
})();
