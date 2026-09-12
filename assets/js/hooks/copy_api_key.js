export default {
  mounted() {
    this.copy = async () => {
      const input = document.getElementById("issued-api-key")
      if (!input?.value) return
      try {
        await navigator.clipboard.writeText(input.value)
        this.el.textContent = "Copied"
      } catch {
        input.focus()
        input.select()
        this.el.textContent = "Select and copy the key"
      }
    }
    this.el.addEventListener("click", this.copy)
  },
  disconnected() {
    const input = document.getElementById("issued-api-key")
    if (input) input.value = ""
  },
  destroyed() {
    this.el.removeEventListener("click", this.copy)
  }
}
