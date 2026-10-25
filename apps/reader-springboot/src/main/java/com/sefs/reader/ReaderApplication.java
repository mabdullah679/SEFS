package com.sefs.reader;

import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.scheduling.annotation.EnableScheduling;

/** SEFS reader: no web server (spring.main.web-application-type=none), one scheduled poller. */
@SpringBootApplication
@EnableScheduling
public class ReaderApplication {
    public static void main(String[] args) {
        SpringApplication.run(ReaderApplication.class, args);
    }
}
