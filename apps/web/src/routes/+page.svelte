<script lang="ts">
	import { goto } from '$app/navigation';
	import { user } from '$lib/stores/auth';

	$effect(() => {
		if ($user) {
			goto('/polls');
		}
	});
</script>

<div class="landing">
	<header>
		<div class="logo">Meeting Scheduler</div>
		<nav>
			<a href="/auth">Sign In</a>
		</nav>
	</header>

	<main>
		<h1>Find the perfect meeting time</h1>
		<p class="tagline">
			Create polls, share with your team, and find when everyone is available.
		</p>
		<div class="cta-buttons">
			<a href="/auth" class="btn primary">Get Started Free</a>
		</div>

		<div class="features">
			<div class="feature">
				<h3>Easy Scheduling</h3>
				<p>Create a poll in seconds. Add time options and share with participants.</p>
			</div>
			<div class="feature">
				<h3>Real-time Updates</h3>
				<p>See responses as they come in. Find the best time instantly.</p>
			</div>
			<div class="feature">
				<h3>Works Everywhere</h3>
				<p>Available on iOS, Android, and Web. Your polls sync across all devices.</p>
			</div>
		</div>
	</main>

	<footer>
		<p>&copy; 2025 Meeting Scheduler</p>
	</footer>
</div>

<style>
	.landing {
		min-height: 100vh;
		display: flex;
		flex-direction: column;
	}

	header {
		display: flex;
		justify-content: space-between;
		align-items: center;
		padding: 1rem 2rem;
		border-bottom: 1px solid #eee;
	}

	.logo {
		font-weight: 600;
		font-size: 1.25rem;
	}

	nav a {
		color: #007bff;
		text-decoration: none;
	}

	nav a:hover {
		text-decoration: underline;
	}

	main {
		flex: 1;
		max-width: 800px;
		margin: 0 auto;
		padding: 4rem 2rem;
		text-align: center;
	}

	h1 {
		font-size: 2.5rem;
		margin: 0 0 1rem;
	}

	.tagline {
		font-size: 1.25rem;
		color: #666;
		margin: 0 0 2rem;
	}

	.cta-buttons {
		margin-bottom: 4rem;
	}

	.btn {
		display: inline-block;
		padding: 1rem 2rem;
		border-radius: 8px;
		text-decoration: none;
		font-weight: 500;
		font-size: 1.125rem;
	}

	.btn.primary {
		background: #007bff;
		color: white;
	}

	.btn.primary:hover {
		background: #0056b3;
	}

	.features {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
		gap: 2rem;
		text-align: left;
	}

	.feature h3 {
		margin: 0 0 0.5rem;
	}

	.feature p {
		margin: 0;
		color: #666;
	}

	footer {
		padding: 2rem;
		text-align: center;
		border-top: 1px solid #eee;
		color: #999;
	}
</style>
