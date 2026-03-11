# m h  dom mon dow   command
0 5 * * * /home/ubuntu/backups/daily.sh
0 8 * * 6 /home/ubuntu/backups/weekly.sh
0 8 15 * * /home/ubuntu/backups/monthly.sh

# Para despliegues aprox 2 horas
#0 2 * * * /home/ubuntu/backups/deploy.sh
