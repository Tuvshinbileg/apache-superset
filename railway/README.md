# Quick Deploy to Railway

[![Deploy on Railway](https://railway.app/button.svg)](https://railway.app/template)

## Apache Superset on Railway

This template deploys Apache Superset with:

- **PostgreSQL 16**: Metadata database
- **Redis 7**: Caching and Celery broker
- **Auto-scaling**: Based on traffic
- **HTTPS**: Automatic SSL certificates
- **Monitoring**: Built-in metrics and logs

## Environment Variables

The following environment variables will be configured automatically:

| Variable | Description | Default |
|----------|-------------|---------|
| `SUPERSET_SECRET_KEY` | Secret key for cookies | Auto-generated |
| `ADMIN_PASSWORD` | Admin user password | `admin` |
| `DATABASE_URL` | PostgreSQL connection | Auto-configured |
| `REDIS_URL` | Redis connection | Auto-configured |
| `WEB_CONCURRENCY` | Number of workers | `4` |

## Post-Deployment

1. **Access Superset**: Click the generated domain in Railway
2. **Login**: Username `admin`, Password from `ADMIN_PASSWORD`
3. **Change Password**: Go to Settings → User Info → Edit Password
4. **Add Data Sources**: Connect your databases

## Custom Domain

1. Go to your service in Railway
2. Settings → Domains → Add Domain
3. Add CNAME record to your DNS

## Scaling

Railway automatically scales based on:
- CPU usage
- Memory usage
- Request load

Configure in: Service Settings → Autoscaling

## Support

- [Railway Docs](https://docs.railway.app/)
- [Superset Docs](https://superset.apache.org/docs/)
- [GitHub Issues](https://github.com/apache/superset/issues)
