// Serve the provisionTenant workflow. Restate discovers handlers over HTTP/2 on
// this port; register the deployment with the Restate server after deploy
// (see README — `restate deployments register`).
import * as restate from '@restatedev/restate-sdk';
import { provisionTenant } from './workflow.js';

restate.serve({ services: [provisionTenant] });
