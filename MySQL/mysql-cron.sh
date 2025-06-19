#!/bin/bash

# Configurations
REPO_URL="https://github.com/mysql/mysql-connector-net.git"
CLONE_DIR="/home/medha/db/MySQL/mysql-connector-net"
LOG_DIR="/home/medha/db/MySQL/logs"
APP_DIR="/home/medha/db/MySQL/MySQL_Test_App"
EMAIL="venkad.krishna@ibm.com,medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"
DOTNET_ROOT="/home/medha/packages/net9"
DB_NAME="TestDB"
TABLE_NAME="Persons"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/mysql_test_log_$(date +'%Y%m%d_%H%M%S').txt"

# Export environment variables for dotnet
export DOTNET_ROOT="$DOTNET_ROOT"
export PATH="$DOTNET_ROOT:$PATH"

# Cleanup function
cleanup() {
    echo "Performing cleanup..." >> "$LOG_FILE"
    rm -rf "$CLONE_DIR" "$APP_DIR"
    mysql -u root -e "DROP DATABASE IF EXISTS $DB_NAME;" >> "$LOG_FILE" 2>&1
}

# Send email function
send_email() {
    local driver_summary
    local app_summary

    # Check for driver build/test success/failure
    if grep -q "Build failed" "$LOG_FILE"; then
        driver_summary="Driver build/test: Failed"
    else
        driver_summary="Driver build/test: Successful"
    fi

    # Check for application success/failure
    if grep -q "Application failed to run" "$LOG_FILE"; then
        app_summary="Application: Failed"
    else
        app_summary="Application: Successful"
    fi

    # Send the email with summary and attachment
    (
        echo "Subject: MySQL Connector Test Results"
        echo "To: $EMAIL"
        echo "Content-Type: multipart/mixed; boundary=\"boundary\""
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; charset=\"UTF-8\""
        echo
        echo "$driver_summary"
        echo "$app_summary"
        echo
        echo "--boundary"
        echo "Content-Type: text/plain; name=\"$(basename "$LOG_FILE")\""
        echo "Content-Disposition: attachment; filename=\"$(basename "$LOG_FILE")\""
        echo
        cat "$LOG_FILE"
        echo
        echo "--boundary--"
    ) | /usr/sbin/sendmail -t
}

# Trap errors to ensure email is sent even on failure
trap 'send_email' EXIT

{
    # Start logging
    echo "Starting MySQL .NET Connector Test Script..." > "$LOG_FILE"

    # Clone the MySQL Connector repository
    echo "Cloning MySQL Connector repository..." >> "$LOG_FILE"
    if [ -d "$CLONE_DIR" ]; then
        rm -rf "$CLONE_DIR"
    fi
    git clone "$REPO_URL" "$CLONE_DIR" >> "$LOG_FILE" 2>&1 || { echo "Failed to clone repository" >> "$LOG_FILE"; exit 1; }

    # Build the connector
    echo "Building MySQL Connector..." >> "$LOG_FILE"
    cd "$CLONE_DIR/MySQL.Data/"
    dotnet build >> "$LOG_FILE" 2>&1 || { echo "Build failed" >> "$LOG_FILE"; exit 1; }

    # Install MySQL server and set up a test database
    echo "Setting up MySQL server and test database..." >> "$LOG_FILE"
    dnf install -y mysql-server >> "$LOG_FILE" 2>&1
    systemctl start mysqld.service >> "$LOG_FILE" 2>&1
    systemctl enable mysqld.service >> "$LOG_FILE" 2>&1
    mysql -u root -e "CREATE DATABASE $DB_NAME;" >> "$LOG_FILE" 2>&1
    mysql -u root -D "$DB_NAME" -e "CREATE TABLE $TABLE_NAME (PersonID int, LastName varchar(255), FirstName varchar(255), Address varchar(255), City varchar(255));" >> "$LOG_FILE" 2>&1
    mysql -u root -D "$DB_NAME" -e "INSERT INTO $TABLE_NAME VALUES (101, 'ABC', 'DEF', 'Street A', 'City A');" >> "$LOG_FILE" 2>&1
    mysql -u root -D "$DB_NAME" -e "INSERT INTO $TABLE_NAME VALUES (102, 'XYZ', 'PQR', 'Street B', 'City B');" >> "$LOG_FILE" 2>&1

    # Create .NET console application
    echo "Creating .NET console application..." >> "$LOG_FILE"
    dotnet new console -o "$APP_DIR" --force >> "$LOG_FILE" 2>&1 || { echo "Failed to create .NET console application" >> "$LOG_FILE"; exit 1; }

    # Add package references and write application code
    echo "Adding MySQL.Data reference and required packages..." >> "$LOG_FILE"
    cd "$APP_DIR"
    dotnet add package MySql.Data >> "$LOG_FILE" 2>&1
    dotnet add package System.Configuration.ConfigurationManager >> "$LOG_FILE" 2>&1
    dotnet add package System.Security.Permissions >> "$LOG_FILE" 2>&1

    cat > Program.cs << EOF
using System;
using MySql.Data.MySqlClient;

namespace MySQL_Test_App
{
    class Program
    {
        static void PrintTable(MySqlConnection connection, string tableName)
        {
            string query = $"SELECT * FROM {tableName}";
            var command = new MySqlCommand(query, connection);
            var reader = command.ExecuteReader();

            int fieldCount = reader.FieldCount;

            Console.WriteLine(":");
            for (int i = 0; i < fieldCount; i++)
            {
                Console.Write(reader.GetName(i) + ":");
            }
            Console.WriteLine();

            while (reader.Read())
            {
                Console.Write(":");
                for (int i = 0; i < fieldCount; i++)
                {
                    Console.Write(reader[i] + ":");
                }
                Console.WriteLine();
            }
            reader.Close();
        }

        static void Main(string[] args)
        {
            string connectionString = "SERVER=localhost;DATABASE=$DB_NAME;UID=root;PWD=;";
            using var connection = new MySqlConnection(connectionString);
            connection.Open();

            Console.WriteLine("Writing to the Database...");
            string insertQuery = "INSERT INTO $TABLE_NAME VALUES (103, 'LMN', 'OPQ', 'Street C', 'City C');";
            var insertCommand = new MySqlCommand(insertQuery, connection);
            insertCommand.ExecuteNonQuery();

            PrintTable(connection, "$TABLE_NAME");

            Console.WriteLine("Updating the Database...");
            string updateQuery = "UPDATE $TABLE_NAME SET LastName='Updated' WHERE PersonID=103;";
            var updateCommand = new MySqlCommand(updateQuery, connection);
            updateCommand.ExecuteNonQuery();

            PrintTable(connection, "$TABLE_NAME");

            Console.WriteLine("Deleting from the Database...");
            string deleteQuery = "DELETE FROM $TABLE_NAME WHERE PersonID=103;";
            var deleteCommand = new MySqlCommand(deleteQuery, connection);
            deleteCommand.ExecuteNonQuery();

            PrintTable(connection, "$TABLE_NAME");
        }
    }
}
EOF

    # Build and run the .NET application
    echo "Building and running the .NET application..." >> "$LOG_FILE"
    dotnet build >> "$LOG_FILE" 2>&1
    dotnet run >> "$LOG_FILE" 2>&1 || { echo "Application failed to run" >> "$LOG_FILE"; exit 1; }

    echo "Script completed successfully." >> "$LOG_FILE"
} || {
    echo "An error occurred during the script execution." >> "$LOG_FILE"
}

# Ensure cleanup is done
cleanup


