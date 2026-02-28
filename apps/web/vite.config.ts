import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [sveltekit()],
	server: {
		host: '0.0.0.0', // Listen on all network interfaces
		port: 5173,
		strictPort: true
	},
	test: {
		environment: 'node',
		include: ['src/**/*.test.ts'],
		alias: {
			'$lib': '/home/user/meeting-scheduler/apps/web/src/lib',
			'$app/environment': '/home/user/meeting-scheduler/apps/web/src/lib/__mocks__/app-environment.ts'
		}
	}
});
