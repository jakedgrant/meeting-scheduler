<script lang="ts">
	let { children } = $props();
</script>

<div class="page">
	<header>
		<a class="logo" href="/">Meetful</a>
		<nav>
			<a href="/about">About</a>
			<a href="/privacy">Privacy</a>
		</nav>
	</header>

	<main>
		{@render children()}
	</main>

	<footer>
		<p>&copy; 2026 Meetful · <a href="mailto:privacy@meetful.app">privacy@meetful.app</a></p>
	</footer>
</div>

<style>
	.page {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
		color: #1c1c1e;
		line-height: 1.6;
	}

	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		gap: 1rem;
		padding: 1rem 2rem;
		border-bottom: 1px solid #eee;
	}

	.logo {
		font-weight: 600;
		font-size: 1.25rem;
		color: inherit;
		text-decoration: none;
	}

	nav {
		display: flex;
		gap: 1.25rem;
	}

	a {
		color: #007bff;
	}

	nav a {
		text-decoration: none;
	}

	nav a:hover {
		text-decoration: underline;
	}

	main {
		flex: 1;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 3rem 1.5rem;
		box-sizing: border-box;
	}

	main :global(h1) {
		font-size: 2.25rem;
		line-height: 1.2;
		margin: 0 0 1rem;
	}

	main :global(h2) {
		font-size: 1.25rem;
		margin: 2.5rem 0 0.5rem;
	}

	main :global(ul),
	main :global(ol) {
		padding-left: 1.25rem;
	}

	main :global(li) {
		margin-bottom: 0.5rem;
	}

	footer {
		padding: 2rem;
		text-align: center;
		border-top: 1px solid #eee;
		color: #999;
	}

	@media (max-width: 480px) {
		header {
			padding: 1rem;
		}
	}
</style>
