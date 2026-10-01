// Filter ability cards by the search box; hide kit groups and specs left empty.
(function () {
  var q = document.getElementById("q");
  if (!q) return;
  q.addEventListener("input", function () {
    var term = q.value.trim().toLowerCase();
    document.querySelectorAll(".ability").forEach(function (a) {
      a.hidden = term !== "" && a.dataset.search.indexOf(term) === -1;
    });
    document.querySelectorAll(".grid").forEach(function (g) {
      var any = g.querySelector(".ability:not([hidden])");
      g.hidden = !any;
      var h = g.previousElementSibling;
      if (h && h.tagName === "H3") h.hidden = !any;
    });
  });
})();
